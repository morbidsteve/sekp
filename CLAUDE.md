# SEKP - SecureEdge Kubernetes Platform

## Project Overview
Build a production-ready, security-first Kubernetes platform deployable with a single command. Supports edge (single-node) and enterprise (HA) environments.

## ⚠️ IMPORTANT: Before Starting Any Work
**ALWAYS read `docs/full-spec.md` before implementing a phase.** It contains:
- Detailed architecture diagrams and traffic flows
- Complete YAML configurations for Istio, Keycloak, storage
- Full CRD schemas (Application, MachineClient, PolicyExemption)
- PEPR policy code (TypeScript)
- Complete install.sh script template
- Test specifications
- Security checklists

Use your file reading capability: "Read docs/full-spec.md" or read specific sections as needed.

## Core Components
| Component | Tool | Purpose |
|-----------|------|---------|
| Service Mesh | Istio | mTLS, traffic management, AuthZ |
| Identity | Keycloak | OIDC for humans, OAuth2 for machines |
| Policy Engine | PEPR | TypeScript admission control |
| Storage | Longhorn | Persistent volumes (edge) |
| Certs | cert-manager | TLS certificate automation |
| Monitoring | Prometheus/Grafana/Loki | Metrics and logs |
| Backup | Velero | Disaster recovery |

## Key Requirements (Non-Negotiable)
1. **Single command install** - `./install.sh` runs as unprivileged user, prompts for sudo when needed
2. **Zero trust auth** - ALL traffic authenticated (humans via Keycloak redirect, machines via mTLS/client-credentials)
3. **Secure by default** - No root containers, no privileged pods, drop all capabilities, read-only rootfs, resource limits required
4. **Exemption process** - PolicyExemption CRD for approved exceptions (with expiration)
5. **Developer abstraction** - `Application` CRD hides Istio/NetworkPolicy/Keycloak complexity

## Git Workflow (GitHub MCP Available)
You have GitHub MCP integration. Use it to:
- Commit changes after completing each component (clear, descriptive messages)
- Push to origin after completing each phase
- Create issues for TODOs or known limitations

Commit frequently. Don't wait until everything is done.

## Directory Structure
```
sekp/
├── install/
│   └── install.sh           # Main installer (Phase 1)
├── deploy/
│   ├── crds/                # CRD definitions (Phase 4)
│   ├── istio/               # Istio configs
│   ├── keycloak/            # Keycloak configs
│   └── pepr/                # PEPR deployment
├── pepr/
│   ├── package.json
│   └── policies/            # TypeScript policies (Phase 3)
├── pkg/                     # Go operator code (Phase 4)
├── cmd/
│   ├── sekp-operator/
│   └── sekp-cli/
├── tests/
├── docs/
│   └── full-spec.md         # Complete specification
└── examples/
```

## Current Phase: 1 - Foundation

### Goals
1. Create directory structure (as shown above)
2. Create `install/install.sh` with:
   - Preflight checks (not root, has sudo, enough resources)
   - Interactive configuration (domain, admin email, environment type)
   - K3s installation (edge/enterprise) or Kind (dev)
   - cert-manager installation + ClusterIssuer setup
   - Istio installation with strict mTLS
   - Basic Gateway configuration
3. Make it executable and test with `--environment dev`

### Success Criteria for Phase 1
- [ ] Running `./install/install.sh` on a clean machine bootstraps a working cluster
- [ ] cert-manager is running and can issue certificates
- [ ] Istio is installed with `STRICT` mTLS enabled
- [ ] Gateway is configured for HTTPS with auto HTTP->HTTPS redirect
- [ ] Script handles errors gracefully with clear messages
- [ ] Works as non-root user (uses sudo only when necessary)

### Reference
Full install.sh template is in `docs/full-spec.md` Section 8.

## All Phases Overview
1. **Foundation** ← CURRENT (install script, K3s, cert-manager, Istio)
2. Identity (Keycloak, OIDC, RequestAuthentication)
3. Policy Engine (PEPR setup, security policies)
4. Application CRD (operator, Deployment/Service/VirtualService generation)
5. Machine Clients (client-credentials, mTLS certs)
6. Storage & Observability (Longhorn, Prometheus, Loki)
7. Operations (Velero, CLI tool)
8. Testing & Hardening (e2e tests, security scans)

## Resource Requirements
| Environment | Nodes | CPU | RAM | Disk |
|-------------|-------|-----|-----|------|
| Edge | 1 | 4 | 8GB | 50GB |
| Enterprise | 3+ | 8 | 16GB | 100GB |
| Dev (Kind) | 1 | 4 | 8GB | 40GB |

## When Stuck
1. Re-read the relevant section of `docs/full-spec.md`
2. Check if there's a code example in the spec
3. Test incrementally - don't write 500 lines then test
4. Commit working pieces before moving on
