#!/usr/bin/env bash
# install.sh - Single command installation for SEKP
#
# REQUIREMENTS:
# - Run as non-root user with sudo access
# - Docker or containerd installed
# - kubectl installed (or will be installed)
# - Minimum 4 CPU, 8GB RAM available
# - 50GB disk space
# - Internet access (or private registry configured)

set -euo pipefail

# ============================================
# CONFIGURATION
# ============================================

# These can be overridden via environment variables or command-line flags
SEKP_DOMAIN="${SEKP_DOMAIN:-}"
SEKP_ENVIRONMENT="${SEKP_ENVIRONMENT:-edge}"  # edge, enterprise, dev
SEKP_K8S_DISTRIBUTION="${SEKP_K8S_DISTRIBUTION:-auto}"  # k3s, kind, auto
SEKP_ADMIN_EMAIL="${SEKP_ADMIN_EMAIL:-}"
SEKP_INSTALL_DIR="${SEKP_INSTALL_DIR:-$HOME/.sekp}"
SEKP_TLS_MODE="${SEKP_TLS_MODE:-self-signed}"  # self-signed, letsencrypt
SEKP_SKIP_CONFIRM="${SEKP_SKIP_CONFIRM:-false}"

# Version information
CERT_MANAGER_VERSION="v1.14.0"
ISTIO_VERSION="1.21.0"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================
# HELPER FUNCTIONS
# ============================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# ============================================
# PREFLIGHT CHECKS
# ============================================

preflight_checks() {
    log_info "Running preflight checks..."

    # Check if running as root (we don't want that)
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run as root. Run as regular user with sudo access."
        exit 1
    fi

    # Check sudo access
    if ! sudo -n true 2>/dev/null; then
        log_info "This script requires sudo access for some operations."
        log_info "You may be prompted for your password."
        sudo -v
    fi

    # Check required tools
    local required_tools=("curl" "git")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "$tool is required but not installed."
            exit 1
        fi
    done

    # Check system resources
    local available_memory=$(free -g | awk '/^Mem:/{print $7}')
    local available_cpus=$(nproc)

    if [[ $available_memory -lt 6 ]]; then
        log_warn "Less than 6GB RAM available. Minimum 8GB recommended."
        log_warn "Available: ${available_memory}GB"
    fi

    if [[ $available_cpus -lt 4 ]]; then
        log_warn "Less than 4 CPUs available. Performance may be degraded."
        log_warn "Available: ${available_cpus} CPUs"
    fi

    # Check disk space
    local available_disk=$(df -BG "$HOME" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $available_disk -lt 40 ]]; then
        log_error "Less than 40GB disk space available in $HOME."
        log_error "Available: ${available_disk}GB"
        exit 1
    fi

    log_success "Preflight checks passed."
}

# ============================================
# INTERACTIVE CONFIGURATION
# ============================================

configure_installation() {
    echo ""
    echo "=========================================="
    echo "   SEKP Installation Configuration"
    echo "=========================================="
    echo ""

    # Domain
    if [[ -z "$SEKP_DOMAIN" ]]; then
        read -p "Enter your domain (e.g., example.com): " SEKP_DOMAIN
        if [[ -z "$SEKP_DOMAIN" ]]; then
            SEKP_DOMAIN="sekp.local"
            log_warn "No domain provided, using default: $SEKP_DOMAIN"
        fi
    fi

    # Admin email
    if [[ -z "$SEKP_ADMIN_EMAIL" ]]; then
        read -p "Enter admin email: " SEKP_ADMIN_EMAIL
        if [[ -z "$SEKP_ADMIN_EMAIL" ]]; then
            SEKP_ADMIN_EMAIL="admin@${SEKP_DOMAIN}"
            log_warn "No email provided, using default: $SEKP_ADMIN_EMAIL"
        fi
    fi

    # Environment (only if not already set via environment variable)
    if [[ "$SEKP_ENVIRONMENT" == "edge" ]] && [[ -z "${SEKP_ENVIRONMENT_SET:-}" ]]; then
        echo ""
        echo "Select environment:"
        echo "  1) edge       - Single node, minimal resources"
        echo "  2) enterprise - Multi-node HA (not implemented in Phase 1)"
        echo "  3) dev        - Local development (Kind)"
        read -p "Choice [1-3] (default: 1): " env_choice
        case $env_choice in
            1|"") SEKP_ENVIRONMENT="edge" ;;
            2)
                log_warn "Enterprise mode will be available in later phases."
                SEKP_ENVIRONMENT="edge"
                ;;
            3) SEKP_ENVIRONMENT="dev" ;;
            *) SEKP_ENVIRONMENT="edge" ;;
        esac
    fi

    # TLS mode
    if [[ "$SEKP_TLS_MODE" == "self-signed" ]] && [[ -z "${SEKP_TLS_MODE_SET:-}" ]]; then
        echo ""
        echo "Select TLS mode:"
        echo "  1) self-signed  - Self-signed certificates (dev/testing)"
        echo "  2) letsencrypt  - Let's Encrypt (requires public DNS)"
        read -p "Choice [1-2] (default: 1): " tls_choice
        case $tls_choice in
            1|"") SEKP_TLS_MODE="self-signed" ;;
            2) SEKP_TLS_MODE="letsencrypt" ;;
            *) SEKP_TLS_MODE="self-signed" ;;
        esac
    fi

    # Summary
    echo ""
    echo "=========================================="
    echo "   Configuration Summary"
    echo "=========================================="
    echo "Domain:      $SEKP_DOMAIN"
    echo "Admin Email: $SEKP_ADMIN_EMAIL"
    echo "Environment: $SEKP_ENVIRONMENT"
    echo "TLS Mode:    $SEKP_TLS_MODE"
    echo "Install Dir: $SEKP_INSTALL_DIR"
    echo "=========================================="
    echo ""

    if [[ "$SEKP_SKIP_CONFIRM" != "true" ]]; then
        read -p "Proceed with installation? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled."
            exit 0
        fi
    fi
}

# ============================================
# KUBERNETES BOOTSTRAP
# ============================================

bootstrap_kubernetes() {
    log_info "Bootstrapping Kubernetes cluster..."

    case $SEKP_K8S_DISTRIBUTION in
        k3s)
            install_k3s
            ;;
        kind)
            install_kind
            ;;
        auto)
            if [[ "$SEKP_ENVIRONMENT" == "dev" ]]; then
                install_kind
            else
                install_k3s
            fi
            ;;
        *)
            log_info "Using existing cluster..."
            ;;
    esac

    # Wait for cluster to be ready
    log_info "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s || {
        log_error "Cluster failed to become ready"
        exit 1
    }

    log_success "Kubernetes cluster is ready"
}

install_k3s() {
    log_info "Installing K3s..."

    # Check if K3s is already installed
    if command -v k3s &>/dev/null; then
        log_info "K3s already installed, skipping..."
        export KUBECONFIG="$HOME/.kube/config"
        return
    fi

    # K3s install options
    local k3s_opts="--disable traefik"  # We use Istio instead
    k3s_opts+=" --disable servicelb"     # We use Istio instead
    k3s_opts+=" --write-kubeconfig-mode 644"

    if [[ "$SEKP_ENVIRONMENT" == "edge" ]]; then
        k3s_opts+=" --node-label sekp.io/node-type=edge"
    fi

    # Install K3s (requires sudo)
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$k3s_opts" sudo sh -

    # Setup kubeconfig for current user
    mkdir -p "$HOME/.kube"
    sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
    sudo chown "$USER:$USER" "$HOME/.kube/config"
    chmod 600 "$HOME/.kube/config"

    export KUBECONFIG="$HOME/.kube/config"

    log_success "K3s installed successfully"
}

install_kind() {
    log_info "Installing Kind..."

    # Check if Kind cluster already exists
    if command -v kind &>/dev/null && kind get clusters 2>/dev/null | grep -q "^sekp$"; then
        log_info "Kind cluster 'sekp' already exists, skipping..."
        export KUBECONFIG="$HOME/.kube/config"
        return
    fi

    # Install Kind if not present
    if ! command -v kind &>/dev/null; then
        log_info "Installing Kind binary..."
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
        chmod +x ./kind
        sudo mv ./kind /usr/local/bin/kind
    fi

    # Install kubectl if not present
    if ! command -v kubectl &>/dev/null; then
        log_info "Installing kubectl..."
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/kubectl
    fi

    # Create Kind config
    cat > /tmp/kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true,sekp.io/node-type=dev"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF

    # Create cluster
    kind create cluster --name sekp --config /tmp/kind-config.yaml

    # Set kubeconfig
    kind export kubeconfig --name sekp
    export KUBECONFIG="$HOME/.kube/config"

    log_success "Kind cluster created successfully"
}

# ============================================
# PLATFORM INSTALLATION
# ============================================

install_platform() {
    log_info "Installing SEKP platform components..."

    # Create install directory
    mkdir -p "$SEKP_INSTALL_DIR"

    # Save configuration
    cat > "$SEKP_INSTALL_DIR/config.env" <<EOF
SEKP_DOMAIN=$SEKP_DOMAIN
SEKP_ENVIRONMENT=$SEKP_ENVIRONMENT
SEKP_ADMIN_EMAIL=$SEKP_ADMIN_EMAIL
SEKP_TLS_MODE=$SEKP_TLS_MODE
SEKP_INSTALL_DIR=$SEKP_INSTALL_DIR
EOF

    # Install in order (Phase 1 components only)
    install_cert_manager
    install_istio

    # Apply default configurations
    apply_default_gateway

    log_success "Platform installation complete"
}

install_cert_manager() {
    log_info "Installing cert-manager..."

    # Check if already installed
    if kubectl get namespace cert-manager &>/dev/null; then
        log_info "cert-manager namespace exists, checking deployment..."
        if kubectl get deployment -n cert-manager cert-manager &>/dev/null; then
            log_info "cert-manager already installed, skipping..."
            return
        fi
    fi

    # Install cert-manager
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

    # Wait for cert-manager to be ready
    log_info "Waiting for cert-manager to be ready..."
    kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s || {
        log_error "cert-manager failed to become ready"
        exit 1
    }

    # Give cert-manager a moment to set up webhooks
    sleep 10

    # Create issuers based on TLS mode
    case $SEKP_TLS_MODE in
        self-signed)
            log_info "Creating self-signed certificate issuer..."
            kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: sekp-selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: sekp-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: sekp-ca
  secretName: sekp-ca-secret
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: sekp-selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
EOF
            # Wait for CA certificate to be ready
            sleep 5
            kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: sekp-issuer
spec:
  ca:
    secretName: sekp-ca-secret
EOF
            ;;
        letsencrypt)
            log_info "Creating Let's Encrypt issuer..."
            kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: sekp-issuer
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $SEKP_ADMIN_EMAIL
    privateKeySecretRef:
      name: letsencrypt-private-key
    solvers:
      - http01:
          ingress:
            class: istio
EOF
            ;;
    esac

    log_success "cert-manager installed and configured"
}

install_istio() {
    log_info "Installing Istio..."

    # Check if already installed
    if kubectl get namespace istio-system &>/dev/null; then
        if kubectl get deployment -n istio-system istiod &>/dev/null; then
            log_info "Istio already installed, skipping..."
            return
        fi
    fi

    # Download and install istioctl
    if ! command -v istioctl &>/dev/null; then
        log_info "Downloading istioctl..."
        curl -L "https://istio.io/downloadIstio" | ISTIO_VERSION=$ISTIO_VERSION sh -
        export PATH="$HOME/istio-${ISTIO_VERSION}/bin:$PATH"
        sudo cp "$HOME/istio-${ISTIO_VERSION}/bin/istioctl" /usr/local/bin/
    fi

    # Determine service type based on environment
    local gateway_service_type="LoadBalancer"
    if [[ "$SEKP_ENVIRONMENT" == "dev" ]]; then
        gateway_service_type="NodePort"
    fi

    # Install Istio with custom configuration
    log_info "Installing Istio components..."
    istioctl install --set profile=minimal -y --set values.global.proxy.resources.requests.cpu=50m --set values.global.proxy.resources.requests.memory=64Mi --set values.global.proxy.resources.limits.cpu=200m --set values.global.proxy.resources.limits.memory=128Mi --set meshConfig.accessLogFile=/dev/stdout --set meshConfig.enableTracing=true --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY --set components.ingressGateways[0].name=istio-ingressgateway --set components.ingressGateways[0].enabled=true --set components.ingressGateways[0].k8s.service.type=$gateway_service_type --set components.ingressGateways[0].k8s.resources.requests.cpu=100m --set components.ingressGateways[0].k8s.resources.requests.memory=128Mi --set components.ingressGateways[0].k8s.resources.limits.cpu=500m --set components.ingressGateways[0].k8s.resources.limits.memory=256Mi

    # Wait for Istio to be ready
    log_info "Waiting for Istio to be ready..."
    kubectl wait --for=condition=Available deployment --all -n istio-system --timeout=300s || {
        log_error "Istio failed to become ready"
        exit 1
    }

    # Enable strict mTLS
    log_info "Enabling strict mTLS..."
    kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF

    log_success "Istio installed with strict mTLS enabled"
}

apply_default_gateway() {
    log_info "Configuring default gateway..."

    # Create wildcard certificate for the gateway
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: sekp-wildcard-cert
  namespace: istio-system
spec:
  secretName: sekp-wildcard-cert
  issuerRef:
    name: sekp-issuer
    kind: ClusterIssuer
    group: cert-manager.io
  dnsNames:
    - "*.${SEKP_DOMAIN}"
    - "${SEKP_DOMAIN}"
EOF

    # Wait for certificate to be ready
    log_info "Waiting for wildcard certificate to be ready..."
    sleep 5
    for i in {1..30}; do
        if kubectl get secret -n istio-system sekp-wildcard-cert &>/dev/null; then
            log_success "Certificate is ready"
            break
        fi
        if [[ $i -eq 30 ]]; then
            log_warn "Certificate not ready yet, but continuing..."
        fi
        sleep 2
    done

    # Create gateway configuration
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: sekp-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: sekp-wildcard-cert
      hosts:
        - "*.${SEKP_DOMAIN}"
        - "${SEKP_DOMAIN}"
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*.${SEKP_DOMAIN}"
        - "${SEKP_DOMAIN}"
      tls:
        httpsRedirect: true
EOF

    log_success "Gateway configured with HTTPS and HTTP->HTTPS redirect"
}

# ============================================
# MAIN
# ============================================

main() {
    echo ""
    echo "=========================================="
    echo "  SEKP - SecureEdge Kubernetes Platform"
    echo "=========================================="
    echo ""

    preflight_checks
    configure_installation
    bootstrap_kubernetes
    install_platform

    echo ""
    echo "=========================================="
    echo "  SEKP Installation Complete! (Phase 1)"
    echo "=========================================="
    echo ""
    log_success "Platform foundation is installed:"
    echo "  ✓ Kubernetes cluster (${SEKP_ENVIRONMENT})"
    echo "  ✓ cert-manager with ${SEKP_TLS_MODE} certificates"
    echo "  ✓ Istio service mesh with STRICT mTLS"
    echo "  ✓ Gateway configured for *.${SEKP_DOMAIN}"
    echo ""
    log_info "Configuration saved to: $SEKP_INSTALL_DIR/config.env"
    echo ""
    log_info "Next steps:"
    echo "  - Phase 2: Identity (Keycloak)"
    echo "  - Phase 3: Policy Engine (PEPR)"
    echo "  - Phase 4: Application CRD"
    echo ""
    log_info "Verify installation:"
    echo "  kubectl get pods -A"
    echo "  kubectl get gateway -n istio-system"
    echo ""
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --domain)
            SEKP_DOMAIN="$2"
            shift 2
            ;;
        --email)
            SEKP_ADMIN_EMAIL="$2"
            shift 2
            ;;
        --environment)
            SEKP_ENVIRONMENT="$2"
            SEKP_ENVIRONMENT_SET=true
            shift 2
            ;;
        --tls-mode)
            SEKP_TLS_MODE="$2"
            SEKP_TLS_MODE_SET=true
            shift 2
            ;;
        --skip-confirm)
            SEKP_SKIP_CONFIRM=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --domain DOMAIN           Set domain (e.g., example.com)"
            echo "  --email EMAIL            Set admin email"
            echo "  --environment ENV        Set environment: edge, enterprise, dev"
            echo "  --tls-mode MODE          Set TLS mode: self-signed, letsencrypt"
            echo "  --skip-confirm           Skip confirmation prompt"
            echo "  --help                   Show this help message"
            echo ""
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

main "$@"
