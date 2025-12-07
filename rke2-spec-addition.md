# RKE2 Production Environment Specification

> **Add this section to docs/full-spec.md after the existing K3s/Kind installation sections**

---

## Production Environment: RKE2

### Why RKE2 for Production

RKE2 (also known as "RKE Government") is Rancher's next-generation Kubernetes distribution focused on security and compliance:

- **CIS Hardened by Default**: Passes CIS Kubernetes Benchmark out of the box
- **FIPS 140-2 Compliant**: Optional FIPS-compliant binaries
- **SELinux Support**: Works with Rocky Linux's SELinux enforcing mode
- **Embedded etcd**: HA without external dependencies
- **Air-gap Friendly**: Easy to deploy in isolated networks
- **Familiar Architecture**: Uses containerd, standard CNI (Canal/Calico/Cilium)

### Production Architecture

```
                    ┌─────────────────────────────────────────┐
                    │           LOAD BALANCER                 │
                    │         (HAProxy/MetalLB)               │
                    │         VIP: 10.0.0.100:6443            │
                    └──────────────┬──────────────────────────┘
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        │                          │                          │
        ▼                          ▼                          ▼
┌───────────────┐        ┌───────────────┐        ┌───────────────┐
│   SERVER 1    │        │   SERVER 2    │        │   SERVER 3    │
│ Control Plane │◄──────►│ Control Plane │◄──────►│ Control Plane │
│  etcd member  │        │  etcd member  │        │  etcd member  │
│  10.0.0.11    │        │  10.0.0.12    │        │  10.0.0.13    │
└───────────────┘        └───────────────┘        └───────────────┘
        │                          │                          │
        └──────────────────────────┼──────────────────────────┘
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        │                          │                          │
        ▼                          ▼                          ▼
┌───────────────┐        ┌───────────────┐        ┌───────────────┐
│   AGENT 1     │        │   AGENT 2     │        │   AGENT N     │
│    Worker     │        │    Worker     │        │    Worker     │
│  10.0.0.21    │        │  10.0.0.22    │        │  10.0.0.2N    │
└───────────────┘        └───────────────┘        └───────────────┘
```

### Resource Requirements (Production)

| Role | Count | CPU | RAM | Disk | Notes |
|------|-------|-----|-----|------|-------|
| Server (control plane) | 3 (min) | 4 cores | 8GB | 100GB SSD | etcd needs fast disk |
| Agent (worker) | 2+ | 8 cores | 16GB | 200GB SSD | Adjust based on workload |
| Load Balancer | 2 | 1 core | 1GB | 10GB | HAProxy or cloud LB |

### RKE2 Installation Functions

Add these functions to `install/install.sh`:

```bash
# ============================================
# RKE2 PRODUCTION INSTALLATION
# ============================================

install_rke2_server() {
    local node_type="${1:-first}"  # first, additional
    local server_url="${2:-}"      # Required for additional nodes
    local token="${3:-}"           # Required for additional nodes
    
    echo "Installing RKE2 server (${node_type} node)..."
    
    # Create RKE2 config directory
    sudo mkdir -p /etc/rancher/rke2
    
    # Generate or use provided token
    if [[ "$node_type" == "first" ]]; then
        RKE2_TOKEN=$(openssl rand -hex 32)
        echo "Generated cluster token: $RKE2_TOKEN"
        echo "SAVE THIS TOKEN - needed to join additional nodes!"
        echo "$RKE2_TOKEN" > "$SEKP_INSTALL_DIR/rke2-token"
        chmod 600 "$SEKP_INSTALL_DIR/rke2-token"
    else
        if [[ -z "$token" || -z "$server_url" ]]; then
            echo "ERROR: Additional server nodes require --server-url and --token"
            exit 1
        fi
        RKE2_TOKEN="$token"
    fi
    
    # Create RKE2 config
    cat <<EOF | sudo tee /etc/rancher/rke2/config.yaml
# CIS Hardening Profile
profile: cis-1.23

# Cluster token
token: ${RKE2_TOKEN}

# TLS SANs for API server certificate
tls-san:
  - ${SEKP_DOMAIN}
  - ${SEKP_API_VIP:-10.0.0.100}
  - $(hostname)
  - $(hostname -I | awk '{print $1}')

# Disable default components we'll replace
disable:
  - rke2-ingress-nginx    # Using Istio instead

# etcd settings
etcd-expose-metrics: true

# Kubelet settings
kubelet-arg:
  - "max-pods=110"
  - "pod-max-pids=4096"
  - "feature-gates=RotateKubeletServerCertificate=true"
  - "protect-kernel-defaults=true"

# Kube API server settings (CIS hardened)
kube-apiserver-arg:
  - "audit-log-path=/var/lib/rancher/rke2/server/logs/audit.log"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=100"
  - "request-timeout=300s"
  - "service-account-lookup=true"

# Kube controller manager settings
kube-controller-manager-arg:
  - "terminated-pod-gc-threshold=1000"
  - "use-service-account-credentials=true"

# Enable SELinux
selinux: true

# Write kubeconfig with restricted permissions
write-kubeconfig-mode: "0600"

# CNI - using Canal (Calico + Flannel) for NetworkPolicy support
cni: canal
EOF

    # Add server URL for additional nodes
    if [[ "$node_type" == "additional" ]]; then
        echo "server: https://${server_url}:9345" | sudo tee -a /etc/rancher/rke2/config.yaml
    fi
    
    # Install RKE2
    curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE="server" sh -
    
    # Enable and start RKE2
    sudo systemctl enable rke2-server.service
    sudo systemctl start rke2-server.service
    
    # Wait for RKE2 to be ready
    echo "Waiting for RKE2 to start (this may take 2-3 minutes)..."
    local retries=60
    while [[ $retries -gt 0 ]]; do
        if sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes &>/dev/null; then
            break
        fi
        sleep 5
        ((retries--))
        echo "  Waiting... ($retries attempts remaining)"
    done
    
    if [[ $retries -eq 0 ]]; then
        echo "ERROR: RKE2 failed to start. Check: sudo journalctl -u rke2-server -f"
        exit 1
    fi
    
    # Setup kubeconfig for current user
    mkdir -p "$HOME/.kube"
    sudo cp /etc/rancher/rke2/rke2.yaml "$HOME/.kube/config"
    sudo chown "$USER:$USER" "$HOME/.kube/config"
    chmod 600 "$HOME/.kube/config"
    
    # Add RKE2 binaries to PATH
    echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> "$HOME/.bashrc"
    export PATH=$PATH:/var/lib/rancher/rke2/bin
    
    # Symlink kubectl for convenience
    sudo ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
    
    echo "RKE2 server installation complete!"
    
    if [[ "$node_type" == "first" ]]; then
        echo ""
        echo "=========================================="
        echo "To add more server nodes, run on each:"
        echo "=========================================="
        echo "./install.sh --environment prod --node-type server \\"
        echo "  --server-url $(hostname -I | awk '{print $1}') \\"
        echo "  --token ${RKE2_TOKEN}"
        echo ""
        echo "=========================================="
        echo "To add worker nodes, run on each:"
        echo "=========================================="
        echo "./install.sh --environment prod --node-type agent \\"
        echo "  --server-url $(hostname -I | awk '{print $1}') \\"
        echo "  --token ${RKE2_TOKEN}"
        echo ""
    fi
}

install_rke2_agent() {
    local server_url="${1:-}"
    local token="${2:-}"
    
    if [[ -z "$server_url" || -z "$token" ]]; then
        echo "ERROR: Agent nodes require --server-url and --token"
        exit 1
    fi
    
    echo "Installing RKE2 agent (worker node)..."
    
    # Create RKE2 config directory
    sudo mkdir -p /etc/rancher/rke2
    
    # Create agent config
    cat <<EOF | sudo tee /etc/rancher/rke2/config.yaml
server: https://${server_url}:9345
token: ${token}

# Enable SELinux
selinux: true

# Kubelet settings
kubelet-arg:
  - "max-pods=110"
  - "pod-max-pids=4096"
  - "protect-kernel-defaults=true"

# Node labels
node-label:
  - "sekp.io/node-type=worker"
EOF

    # Install RKE2 agent
    curl -sfL https://get.rke2.io | sudo INSTALL_RKE2_TYPE="agent" sh -
    
    # Enable and start RKE2 agent
    sudo systemctl enable rke2-agent.service
    sudo systemctl start rke2-agent.service
    
    echo "Waiting for agent to join cluster..."
    sleep 30
    
    echo "RKE2 agent installation complete!"
    echo "Check node status from a server node: kubectl get nodes"
}

# ============================================
# RKE2 PREREQUISITES
# ============================================

prepare_rke2_host() {
    echo "Preparing host for RKE2..."
    
    # Disable swap (required for Kubernetes)
    sudo swapoff -a
    sudo sed -i '/ swap / s/^/#/' /etc/fstab
    
    # Load required kernel modules
    cat <<EOF | sudo tee /etc/modules-load.d/rke2.conf
br_netfilter
overlay
EOF
    sudo modprobe br_netfilter
    sudo modprobe overlay
    
    # Set required sysctl params
    cat <<EOF | sudo tee /etc/sysctl.d/99-rke2.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
vm.panic_on_oom                     = 0
vm.overcommit_memory                = 1
kernel.panic                        = 10
kernel.panic_on_oops                = 1
EOF
    sudo sysctl --system
    
    # Configure firewall for RKE2 (if firewalld is running)
    if systemctl is-active --quiet firewalld; then
        echo "Configuring firewalld for RKE2..."
        
        # Server ports
        sudo firewall-cmd --permanent --add-port=6443/tcp   # Kubernetes API
        sudo firewall-cmd --permanent --add-port=9345/tcp   # RKE2 supervisor API
        sudo firewall-cmd --permanent --add-port=2379/tcp   # etcd client
        sudo firewall-cmd --permanent --add-port=2380/tcp   # etcd peer
        sudo firewall-cmd --permanent --add-port=10250/tcp  # Kubelet metrics
        sudo firewall-cmd --permanent --add-port=10257/tcp  # kube-controller-manager
        sudo firewall-cmd --permanent --add-port=10259/tcp  # kube-scheduler
        
        # CNI ports (Canal/Flannel)
        sudo firewall-cmd --permanent --add-port=8472/udp   # VXLAN
        sudo firewall-cmd --permanent --add-port=4789/udp   # VXLAN (alternate)
        
        # NodePort range
        sudo firewall-cmd --permanent --add-port=30000-32767/tcp
        
        # Reload firewall
        sudo firewall-cmd --reload
    fi
    
    # Set SELinux to permissive temporarily during install, then enforcing
    # RKE2 supports SELinux enforcing but needs proper context
    if command -v getenforce &>/dev/null; then
        if [[ "$(getenforce)" == "Enforcing" ]]; then
            echo "SELinux is enforcing - RKE2 will configure appropriate contexts"
        fi
    fi
    
    # Install required packages
    sudo dnf install -y \
        iptables \
        container-selinux \
        iptables-ebtables \
        ethtool \
        socat \
        conntrack-tools
    
    echo "Host preparation complete."
}
```

### Updated Environment Handling

Update the main `bootstrap_kubernetes()` function:

```bash
bootstrap_kubernetes() {
    echo "Bootstrapping Kubernetes cluster..."
    
    case $SEKP_ENVIRONMENT in
        dev)
            install_kind
            ;;
        edge)
            install_k3s
            ;;
        prod)
            prepare_rke2_host
            case $SEKP_NODE_TYPE in
                server)
                    if [[ -z "$SEKP_SERVER_URL" ]]; then
                        # First server node
                        install_rke2_server "first"
                    else
                        # Additional server node
                        install_rke2_server "additional" "$SEKP_SERVER_URL" "$SEKP_TOKEN"
                    fi
                    ;;
                agent)
                    install_rke2_agent "$SEKP_SERVER_URL" "$SEKP_TOKEN"
                    ;;
                *)
                    # Default: first server node
                    install_rke2_server "first"
                    ;;
            esac
            ;;
        *)
            echo "ERROR: Unknown environment: $SEKP_ENVIRONMENT"
            exit 1
            ;;
    esac
    
    # Wait for cluster to be ready (only on server/control nodes)
    if [[ "$SEKP_NODE_TYPE" != "agent" ]]; then
        echo "Waiting for cluster to be ready..."
        kubectl wait --for=condition=Ready nodes --all --timeout=300s
    fi
}
```

### CLI Arguments for Production

Add these to the argument parsing section:

```bash
# ============================================
# ARGUMENT PARSING
# ============================================

SEKP_ENVIRONMENT="${SEKP_ENVIRONMENT:-}"
SEKP_NODE_TYPE="${SEKP_NODE_TYPE:-}"
SEKP_SERVER_URL="${SEKP_SERVER_URL:-}"
SEKP_TOKEN="${SEKP_TOKEN:-}"
SEKP_API_VIP="${SEKP_API_VIP:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --environment|-e)
            SEKP_ENVIRONMENT="$2"
            shift 2
            ;;
        --node-type)
            SEKP_NODE_TYPE="$2"
            shift 2
            ;;
        --server-url)
            SEKP_SERVER_URL="$2"
            shift 2
            ;;
        --token)
            SEKP_TOKEN="$2"
            shift 2
            ;;
        --api-vip)
            SEKP_API_VIP="$2"
            shift 2
            ;;
        --domain|-d)
            SEKP_DOMAIN="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done
```

### Production-Specific Component Configuration

#### Longhorn for Production (3 replicas)

```bash
install_storage() {
    echo "Installing storage solution..."
    
    case $SEKP_ENVIRONMENT in
        dev)
            # Local path provisioner for Kind
            kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
            ;;
        edge)
            install_longhorn 1  # 1 replica for edge
            ;;
        prod)
            install_longhorn 3  # 3 replicas for production HA
            ;;
    esac
}

install_longhorn() {
    local replicas="${1:-2}"
    
    echo "Installing Longhorn with ${replicas} replicas..."
    
    # Install Longhorn prerequisites
    sudo dnf install -y iscsi-initiator-utils nfs-utils
    sudo systemctl enable --now iscsid
    
    # Install Longhorn
    kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.6.0/deploy/longhorn.yaml
    
    # Wait for Longhorn to be ready
    echo "Waiting for Longhorn (this may take a few minutes)..."
    kubectl wait --for=condition=Available deployment --all -n longhorn-system --timeout=600s
    
    # Configure default replica count
    kubectl patch settings default-replica-count -n longhorn-system --type='json' \
        -p="[{\"op\": \"replace\", \"path\": \"/value\", \"value\": \"${replicas}\"}]" || true
    
    # Create storage classes
    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sekp-standard
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "${replicas}"
  staleReplicaTimeout: "2880"
  fsType: "ext4"
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sekp-fast
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  numberOfReplicas: "${replicas}"
  diskSelector: "ssd"
  fsType: "ext4"
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sekp-backup
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
parameters:
  numberOfReplicas: "${replicas}"
  recurringJobs: '[{"name": "daily-backup", "task": "backup", "cron": "0 2 * * ?", "retain": 14}]'
EOF
    
    echo "Longhorn installation complete."
}
```

#### cert-manager for Production (Let's Encrypt)

```bash
install_cert_manager() {
    echo "Installing cert-manager..."
    
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
    kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s
    
    case $SEKP_ENVIRONMENT in
        dev)
            create_selfsigned_issuer
            ;;
        edge)
            if [[ "$SEKP_TLS_MODE" == "letsencrypt" ]]; then
                create_letsencrypt_issuer
            else
                create_selfsigned_issuer
            fi
            ;;
        prod)
            # Production always uses real certificates
            create_letsencrypt_issuer
            ;;
    esac
}

create_letsencrypt_issuer() {
    echo "Creating Let's Encrypt issuer for production..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: sekp-issuer
spec:
  acme:
    # Use production Let's Encrypt
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${SEKP_ADMIN_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-private-key
    solvers:
      - http01:
          ingress:
            class: istio
---
# Also create a staging issuer for testing
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: sekp-issuer-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${SEKP_ADMIN_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-private-key
    solvers:
      - http01:
          ingress:
            class: istio
EOF
    
    echo "Let's Encrypt issuers created."
}
```

### Production Deployment Workflow

For a 3-server + 2-worker production deployment:

```bash
# ========================================
# NODE 1 (First Control Plane)
# ========================================
./install.sh --environment prod --domain example.com

# Save the token shown in output!
# TOKEN=abc123...

# ========================================
# NODE 2 & 3 (Additional Control Planes)
# ========================================
./install.sh --environment prod \
  --node-type server \
  --server-url 10.0.0.11 \
  --token abc123...

# ========================================
# NODE 4 & 5 (Workers)
# ========================================
./install.sh --environment prod \
  --node-type agent \
  --server-url 10.0.0.11 \
  --token abc123...

# ========================================
# VERIFY CLUSTER
# ========================================
kubectl get nodes
# NAME      STATUS   ROLES                       AGE   VERSION
# node-1    Ready    control-plane,etcd,master   10m   v1.28.x+rke2r1
# node-2    Ready    control-plane,etcd,master   8m    v1.28.x+rke2r1
# node-3    Ready    control-plane,etcd,master   6m    v1.28.x+rke2r1
# node-4    Ready    <none>                      4m    v1.28.x+rke2r1
# node-5    Ready    <none>                      2m    v1.28.x+rke2r1
```

### Load Balancer Consideration

For production HA, you need a load balancer in front of control plane nodes. Options:

1. **Cloud LB**: If running in AWS/GCP/Azure, use their native LB
2. **MetalLB**: For bare metal, install MetalLB for LoadBalancer service type
3. **HAProxy/Keepalived**: Traditional HA pair with VIP
4. **kube-vip**: Kubernetes-native VIP for control plane

Add to install.sh for bare metal:

```bash
install_metallb() {
    echo "Installing MetalLB for bare metal load balancing..."
    
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.0/config/manifests/metallb-native.yaml
    kubectl wait --for=condition=Available deployment controller -n metallb-system --timeout=300s
    
    # Configure IP pool (adjust for your network)
    cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: sekp-pool
  namespace: metallb-system
spec:
  addresses:
    - ${SEKP_LB_RANGE:-10.0.0.200-10.0.0.250}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: sekp-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - sekp-pool
EOF
    
    echo "MetalLB installed."
}
```

---

## Summary Table: Environment Differences

| Feature | dev | edge | prod |
|---------|-----|------|------|
| K8s Distribution | Kind | K3s | RKE2 |
| Nodes | 1 (containers) | 1-3 | 3+ servers, 2+ agents |
| HA | No | Optional | Required |
| CIS Hardened | No | No | Yes |
| SELinux | No | Optional | Yes |
| Storage Replicas | 1 | 1-2 | 3 |
| TLS Certificates | Self-signed | Self-signed/LE | Let's Encrypt |
| Audit Logging | No | Optional | Yes |
| Firewall Config | No | Optional | Yes |

---

## Updated CLAUDE.md Phase Reference

Update the phases in CLAUDE.md to reflect multi-environment support:

```markdown
## Phase 1 - Foundation (Updated)

### Goals
1. Create directory structure
2. Create `install/install.sh` supporting:
   - `--environment dev` → Kind
   - `--environment edge` → K3s  
   - `--environment prod` → RKE2 (with --node-type, --server-url, --token)
3. Install cert-manager (self-signed for dev, Let's Encrypt for prod)
4. Install Istio with strict mTLS
5. Set up Gateway

### Success Criteria
- [ ] `./install.sh --environment dev` works on a dev machine with Docker
- [ ] `./install.sh --environment edge` works on a single Rocky node
- [ ] `./install.sh --environment prod` bootstraps first RKE2 server
- [ ] Additional server/agent nodes can join with --server-url and --token
- [ ] All environments get Istio with strict mTLS
- [ ] Production uses Let's Encrypt, others use self-signed
```
