# SEKP Installation

This directory contains the installation script for the SecureEdge Kubernetes Platform (SEKP).

## Quick Start

### Prerequisites

- Linux system with sudo access
- Minimum 4 CPU cores, 8GB RAM, 50GB disk space
- `curl` and `git` installed
- Internet access (for downloading components)

### Interactive Installation

Run the installation script:

```bash
./install.sh
```

The script will:
1. Check system requirements
2. Prompt for configuration (domain, email, environment type)
3. Install Kubernetes (K3s for edge/enterprise, Kind for dev)
4. Install cert-manager with certificate issuers
5. Install Istio service mesh with strict mTLS
6. Configure the default gateway

### Non-Interactive Installation

You can provide configuration via command-line arguments:

```bash
./install.sh \
  --domain example.com \
  --email admin@example.com \
  --environment dev \
  --tls-mode self-signed \
  --skip-confirm
```

### Environment Options

- **edge**: Single-node deployment using K3s (default)
- **enterprise**: Multi-node HA deployment using K3s (available in later phases)
- **dev**: Local development using Kind

### TLS Modes

- **self-signed**: Self-signed certificates (good for dev/testing)
- **letsencrypt**: Let's Encrypt certificates (requires public DNS)

## Environment Variables

You can also configure via environment variables:

```bash
export SEKP_DOMAIN="example.com"
export SEKP_ADMIN_EMAIL="admin@example.com"
export SEKP_ENVIRONMENT="dev"
export SEKP_TLS_MODE="self-signed"
./install.sh
```

## What Gets Installed (Phase 1)

Phase 1 installs the foundation:

- **Kubernetes**: K3s (edge/enterprise) or Kind (dev)
- **cert-manager**: Automatic certificate management
- **Istio**: Service mesh with strict mTLS enabled
- **Gateway**: HTTPS gateway with HTTP->HTTPS redirect

## Verification

After installation, verify the components:

```bash
# Check all pods are running
kubectl get pods -A

# Check cert-manager
kubectl get pods -n cert-manager

# Check Istio
kubectl get pods -n istio-system

# Check gateway configuration
kubectl get gateway -n istio-system

# Check certificate
kubectl get certificate -n istio-system
```

## Configuration Files

Installation configuration is saved to `~/.sekp/config.env`

## Uninstallation

For Kind clusters:
```bash
kind delete cluster --name sekp
```

For K3s clusters:
```bash
/usr/local/bin/k3s-uninstall.sh
```

## Troubleshooting

### Installation fails during preflight checks
- Ensure you have sufficient system resources
- Check that you have sudo access: `sudo -v`
- Verify required tools are installed: `curl --version`, `git --version`

### Pods not starting
- Check resource constraints: `kubectl top nodes`
- View pod logs: `kubectl logs -n <namespace> <pod-name>`
- Check events: `kubectl get events -A --sort-by='.lastTimestamp'`

### Certificate not ready
- Check cert-manager logs: `kubectl logs -n cert-manager deployment/cert-manager`
- Verify issuer: `kubectl get clusterissuer`
- Check certificate status: `kubectl describe certificate -n istio-system sekp-wildcard-cert`

## Next Steps

After Phase 1 completes successfully:
- Phase 2: Install Keycloak for identity management
- Phase 3: Install PEPR policy engine
- Phase 4: Deploy Application CRD and operator
- Phase 5: Add machine client authentication
- Phase 6: Install storage (Longhorn) and monitoring
- Phase 7: Add backup/restore with Velero
- Phase 8: Testing and hardening

## Help

For more information:
```bash
./install.sh --help
```

See the main documentation: `../docs/full-spec.md`
