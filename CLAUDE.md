# PROJECT: SecureEdge Kubernetes Platform (SEKP)

## EXECUTIVE SUMMARY

Build a production-ready, security-first Kubernetes platform that can be deployed with a single command. The platform must support both edge deployments and enterprise environments, with mandatory authentication for all human users via Keycloak, mTLS for machine-to-machine communication, policy enforcement preventing insecure configurations, and a developer-friendly abstraction layer via Custom Resource Definitions (CRDs).

---

## TABLE OF CONTENTS

1. [Project Overview & Philosophy](#1-project-overview--philosophy)
2. [Technical Requirements](#2-technical-requirements)
3. [Architecture Specification](#3-architecture-specification)
4. [Component Specifications](#4-component-specifications)
5. [Custom Resource Definitions](#5-custom-resource-definitions)
6. [Security Requirements](#6-security-requirements)
7. [Policy Enforcement](#7-policy-enforcement)
8. [Installation & Bootstrap](#8-installation--bootstrap)
9. [Testing Requirements](#9-testing-requirements)
10. [Documentation Requirements](#10-documentation-requirements)
11. [Directory Structure](#11-directory-structure)
12. [Implementation Order](#12-implementation-order)

---

## 1. PROJECT OVERVIEW & PHILOSOPHY

### 1.1 Core Principles

1. **Security by Default**: Every component must be secure out of the box. No insecure defaults.
2. **Zero Trust**: Never trust, always verify. All traffic authenticated and encrypted.
3. **Minimal Footprint**: Only include what's necessary. Optimize for edge deployment.
4. **Developer Experience**: Abstract complexity. Developers should not need to understand Istio or Keycloak internals.
5. **Observable**: Everything must be auditable and monitorable.
6. **GitOps Ready**: All configurations declarative and version-controllable.

### 1.2 Target Environments

- **Edge**: Single-node or 3-node clusters with limited resources (minimum 4 CPU, 8GB RAM per node)
- **Enterprise**: Multi-node clusters with high availability requirements
- **Cloud**: AWS EKS, GCP GKE, Azure AKS compatibility
- **Bare Metal**: Direct installation on physical servers
- **Local Development**: Kind, K3s, or Minikube for testing

### 1.3 Supported Kubernetes Distributions

- K3s (primary target for edge)
- K8s vanilla (enterprise)
- Kind (development/testing)
- EKS/GKE/AKS (cloud)

---

## 2. TECHNICAL REQUIREMENTS

### 2.1 Core Platform Components

| Component | Purpose | Implementation |
|-----------|---------|----------------|
| Service Mesh | Traffic management, mTLS, observability | Istio (ambient mode for lightweight, sidecar for full features) |
| Identity Provider | User authentication, SSO, OIDC | Keycloak |
| Policy Engine | Admission control, runtime policies | PEPR (TypeScript-based, lightweight) |
| Storage | Persistent volumes, backups | Longhorn (edge) / CSI drivers (cloud) |
| Secrets Management | Secure secret storage | External Secrets Operator + Sealed Secrets |
| Certificate Management | TLS certificates | cert-manager with internal CA + Let's Encrypt |
| Ingress | External traffic routing | Istio Gateway (replaces traditional ingress) |
| DNS | Internal service discovery | CoreDNS (standard) + External-DNS for public |
| Monitoring | Metrics, alerting | Prometheus + Grafana (lightweight stack) |
| Logging | Centralized logging | Loki + Promtail |
| Backup | Disaster recovery | Velero |

### 2.2 Resource Requirements

#### Minimum (Edge/Single Node)
```yaml
nodes: 1
cpu_per_node: 4 cores
memory_per_node: 8GB
storage_per_node: 50GB SSD
```

#### Recommended (Production)
```yaml
nodes: 3+
cpu_per_node: 8 cores
memory_per_node: 16GB
storage_per_node: 100GB SSD
```

### 2.3 Network Requirements

- Ports 80, 443 accessible from internet (if public)
- Ports 6443 (API server) restricted to admin networks
- Inter-node communication on private network
- Outbound internet for pulling images (or private registry)

---

## 3. ARCHITECTURE SPECIFICATION

### 3.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              EXTERNAL TRAFFIC                                │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ISTIO GATEWAY (L7)                                 │
│                    TLS Termination, Rate Limiting                            │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                    ┌─────────────────┴─────────────────┐
                    ▼                                   ▼
┌─────────────────────────────────┐   ┌─────────────────────────────────────┐
│     HUMAN TRAFFIC (Browser)     │   │   MACHINE TRAFFIC (API/Service)     │
│                                 │   │                                     │
│  ┌───────────────────────────┐  │   │  ┌─────────────────────────────┐   │
│  │   KEYCLOAK OIDC REDIRECT  │  │   │  │  mTLS + JWT/API Key Auth    │   │
│  │   (Authorization Code)    │  │   │  │  (Service Account Token)    │   │
│  └───────────────────────────┘  │   │  └─────────────────────────────┘   │
└─────────────────────────────────┘   └─────────────────────────────────────┘
                    │                                   │
                    └─────────────────┬─────────────────┘
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      ISTIO AUTHORIZATION POLICIES                            │
│              (Enforce authentication, RBAC, rate limits)                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           APPLICATION NAMESPACE                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │   App Pod   │  │   App Pod   │  │   App Pod   │  │   App Pod   │        │
│  │  (sidecar)  │  │  (sidecar)  │  │  (sidecar)  │  │  (sidecar)  │        │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              PLATFORM SERVICES                               │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐          │
│  │ Keycloak │ │ Longhorn │ │Prometheus│ │   Loki   │ │  Velero  │          │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘ └──────────┘          │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Namespace Architecture

```yaml
namespaces:
  # Core platform - locked down, no user deployments
  - name: istio-system
    purpose: Istio control plane
    policies: platform-admin-only
    
  - name: keycloak
    purpose: Identity provider
    policies: platform-admin-only
    
  - name: pepr-system
    purpose: Policy enforcement
    policies: platform-admin-only
    
  - name: cert-manager
    purpose: Certificate management
    policies: platform-admin-only
    
  - name: monitoring
    purpose: Prometheus, Grafana, Loki
    policies: platform-admin-only
    
  - name: storage-system
    purpose: Longhorn/storage controllers
    policies: platform-admin-only
    
  - name: sekp-system
    purpose: Platform CRD controllers, operators
    policies: platform-admin-only
    
  - name: velero
    purpose: Backup/restore
    policies: platform-admin-only
    
  # Application namespaces - created per-team/per-app
  - name: apps-*
    purpose: User applications (dynamically created)
    policies: enforced-by-pepr
```

### 3.3 Traffic Flow Specifications

#### 3.3.1 Human User Flow (Browser)
```
1. User navigates to https://app.example.com
2. Istio Gateway receives request
3. EnvoyFilter checks for valid JWT token in cookie/header
4. If no token: Redirect to Keycloak login (https://auth.example.com)
5. User authenticates with Keycloak (username/password, SSO, MFA)
6. Keycloak redirects back with authorization code
7. Token exchange happens (code -> tokens)
8. JWT stored in secure HTTP-only cookie
9. Request proceeds to application with JWT
10. Istio AuthorizationPolicy validates JWT claims
11. Request forwarded to application pod
```

#### 3.3.2 Machine/API Flow (Non-Person Entity)
```
Option A: Service Account Token (Internal)
1. Pod has ServiceAccount with SPIFFE identity
2. mTLS established automatically via Istio
3. Istio validates SPIFFE identity against AuthorizationPolicy
4. Request proceeds if authorized

Option B: API Key/Client Credentials (External)
1. External service calls API with client credentials
2. Client presents either:
   - OAuth2 client_credentials grant -> JWT
   - API Key in header (validated against Keycloak)
3. Istio validates token/key
4. Request proceeds if authorized

Option C: mTLS Certificate (External Machine)
1. External system presents client certificate
2. Istio validates certificate against trusted CA
3. Certificate CN/SAN mapped to identity
4. AuthorizationPolicy enforces access
```

---

## 4. COMPONENT SPECIFICATIONS

### 4.1 Istio Configuration

#### 4.1.1 Installation Profile
```yaml
# Create a custom Istio profile optimized for security and edge deployment
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: sekp-istio
  namespace: istio-system
spec:
  profile: minimal  # Start minimal, add only what's needed
  
  meshConfig:
    # Strict mTLS everywhere
    mtls:
      mode: STRICT
    
    # Enable access logging
    accessLogFile: /dev/stdout
    accessLogFormat: |
      [%START_TIME%] "%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%"
      %RESPONSE_CODE% %RESPONSE_FLAGS% %BYTES_RECEIVED% %BYTES_SENT%
      %DURATION% "%REQ(X-FORWARDED-FOR)%" "%REQ(USER-AGENT)%"
      "%REQ(X-REQUEST-ID)%" "%REQ(:AUTHORITY)%" "%UPSTREAM_HOST%"
      "%UPSTREAM_CLUSTER%" "%REQ(X-JWT-CLAIM-SUB)%"
    
    # Default tracing
    enableTracing: true
    
    # Outbound traffic policy
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY  # Only allow traffic to known services
    
    # Default authorization deny
    extensionProviders:
      - name: keycloak-jwt
        envoyExtAuthz:
          service: keycloak.keycloak.svc.cluster.local
          port: 8080
          
  components:
    # Ingress gateway - single entry point
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          hpaSpec:
            minReplicas: 1
            maxReplicas: 3
          
    # Egress gateway - controlled outbound
    egressGateways:
      - name: istio-egressgateway
        enabled: true
        
    # Control plane
    pilot:
      enabled: true
      k8s:
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
            
  values:
    global:
      # Proxy resources (sidecar)
      proxy:
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
      
      # Log level
      logging:
        level: "default:info"
```

#### 4.1.2 Gateway Configuration
```yaml
apiVersion: networking.istio.io/v1
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
        credentialName: sekp-wildcard-cert  # Managed by cert-manager
      hosts:
        - "*.${DOMAIN}"
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*.${DOMAIN}"
      # Redirect all HTTP to HTTPS
      tls:
        httpsRedirect: true
```

#### 4.1.3 Default Authorization Policy (Deny All)
```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all-default
  namespace: istio-system
spec:
  # Empty selector = applies to all workloads
  {}
  # No rules = deny all
---
# Allow health checks from gateway
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-health-checks
  namespace: istio-system
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  rules:
    - to:
        - operation:
            paths: ["/health", "/ready", "/healthz"]
```

### 4.2 Keycloak Configuration

#### 4.2.1 Deployment Specifications
```yaml
deployment:
  replicas: 2  # HA for production, 1 for edge
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi
  
database:
  # Use embedded H2 for edge, PostgreSQL for production
  edge_mode: embedded-h2
  production_mode: postgresql
  
  postgresql:
    replicas: 2
    resources:
      requests:
        cpu: 250m
        memory: 256Mi
```

#### 4.2.2 Realm Configuration
```yaml
# Platform realm for managing the platform itself
platform_realm:
  name: sekp-platform
  
  clients:
    - clientId: sekp-admin-ui
      protocol: openid-connect
      publicClient: true
      standardFlowEnabled: true
      directAccessGrantsEnabled: false
      rootUrl: https://admin.${DOMAIN}
      redirectUris:
        - https://admin.${DOMAIN}/*
      webOrigins:
        - https://admin.${DOMAIN}
        
    - clientId: istio-ingress
      protocol: openid-connect
      publicClient: false
      serviceAccountsEnabled: true
      clientAuthenticatorType: client-secret
      
  roles:
    realm:
      - name: platform-admin
        description: Full platform administration
      - name: developer
        description: Can deploy applications
      - name: viewer
        description: Read-only access
        
  groups:
    - name: platform-admins
      realmRoles: [platform-admin]
    - name: developers
      realmRoles: [developer]
    - name: viewers
      realmRoles: [viewer]

# Application realm template (created per-tenant)
application_realm_template:
  name: "apps-${TENANT_NAME}"
  
  clients:
    # Machine client template
    - clientId: "${APP_NAME}-service"
      protocol: openid-connect
      publicClient: false
      serviceAccountsEnabled: true
      clientAuthenticatorType: client-secret
      
    # Frontend app template
    - clientId: "${APP_NAME}-ui"
      protocol: openid-connect
      publicClient: true
      standardFlowEnabled: true
```

#### 4.2.3 OIDC Integration with Istio
```yaml
# RequestAuthentication to validate JWTs
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: keycloak-jwt-auth
  namespace: istio-system
spec:
  jwtRules:
    - issuer: "https://auth.${DOMAIN}/realms/sekp-platform"
      jwksUri: "https://auth.${DOMAIN}/realms/sekp-platform/protocol/openid-connect/certs"
      audiences:
        - istio-ingress
      forwardOriginalToken: true
      outputClaimToHeaders:
        - header: x-jwt-claim-sub
          claim: sub
        - header: x-jwt-claim-email
          claim: email
        - header: x-jwt-claim-groups
          claim: groups
```

### 4.3 PEPR Policy Engine

#### 4.3.1 Why PEPR over alternatives
```markdown
Comparison:
- OPA/Gatekeeper: Rego language has steep learning curve
- Kyverno: YAML-only, limited for complex policies
- PEPR: TypeScript, familiar to developers, lightweight, powerful

PEPR Advantages:
1. TypeScript = type safety, IDE support, familiar syntax
2. Built on Kubernetes controller pattern
3. Can do admission control AND runtime watching
4. Lightweight single binary
5. Easy to test with standard testing frameworks
```

#### 4.3.2 Core Policies to Implement
```typescript
// File: policies/security-policies.ts

import { Capability, a, Log } from "pepr";

export const SecurityPolicies = new Capability({
  name: "security-policies",
  description: "Core security policies for SEKP",
  namespaces: [], // All namespaces
});

const { When } = SecurityPolicies;

// ============================================
// POLICY 1: No Root Containers
// ============================================
When(a.Pod)
  .IsCreatedOrUpdated()
  .Validate((request) => {
    const pod = request.Raw;
    
    // Check for platform exemption annotation
    const exemptions = pod.metadata?.annotations?.["sekp.io/policy-exemptions"];
    if (exemptions?.includes("allow-root")) {
      Log.info(`Pod ${pod.metadata?.name} has root exemption`);
      return request.Approve();
    }
    
    // Check all containers
    const allContainers = [
      ...(pod.spec?.containers || []),
      ...(pod.spec?.initContainers || []),
    ];
    
    for (const container of allContainers) {
      const sc = container.securityContext;
      
      // Must explicitly set runAsNonRoot: true
      if (sc?.runAsNonRoot !== true) {
        return request.Deny(
          `Container '${container.name}' must set securityContext.runAsNonRoot: true`
        );
      }
      
      // Must not run as UID 0
      if (sc?.runAsUser === 0) {
        return request.Deny(
          `Container '${container.name}' cannot run as UID 0`
        );
      }
    }
    
    return request.Approve();
  });

// ============================================
// POLICY 2: No Privileged Containers
// ============================================
When(a.Pod)
  .IsCreatedOrUpdated()
  .Validate((request) => {
    const pod = request.Raw;
    const exemptions = pod.metadata?.annotations?.["sekp.io/policy-exemptions"];
    
    const allContainers = [
      ...(pod.spec?.containers || []),
      ...(pod.spec?.initContainers || []),
    ];
    
    for (const container of allContainers) {
      const sc = container.securityContext;
      
      if (sc?.privileged === true) {
        if (!exemptions?.includes("allow-privileged")) {
          return request.Deny(
            `Container '${container.name}' cannot be privileged without exemption`
          );
        }
      }
      
      // No privilege escalation
      if (sc?.allowPrivilegeEscalation !== false) {
        return request.Deny(
          `Container '${container.name}' must set allowPrivilegeEscalation: false`
        );
      }
    }
    
    return request.Approve();
  });

// ============================================
// POLICY 3: Required Security Context
// ============================================
When(a.Pod)
  .IsCreatedOrUpdated()
  .Validate((request) => {
    const pod = request.Raw;
    
    const allContainers = [
      ...(pod.spec?.containers || []),
      ...(pod.spec?.initContainers || []),
    ];
    
    for (const container of allContainers) {
      const sc = container.securityContext;
      
      // Must drop ALL capabilities
      if (!sc?.capabilities?.drop?.includes("ALL")) {
        return request.Deny(
          `Container '${container.name}' must drop ALL capabilities`
        );
      }
      
      // Must have read-only root filesystem
      if (sc?.readOnlyRootFilesystem !== true) {
        return request.Deny(
          `Container '${container.name}' must set readOnlyRootFilesystem: true`
        );
      }
    }
    
    return request.Approve();
  });

// ============================================
// POLICY 4: No hostPath Volumes
// ============================================
When(a.Pod)
  .IsCreatedOrUpdated()
  .Validate((request) => {
    const pod = request.Raw;
    const exemptions = pod.metadata?.annotations?.["sekp.io/policy-exemptions"];
    
    const volumes = pod.spec?.volumes || [];
    
    for (const volume of volumes) {
      if (volume.hostPath) {
        if (!exemptions?.includes("allow-hostpath")) {
          return request.Deny(
            `Volume '${volume.name}' uses hostPath which is not allowed`
          );
        }
      }
    }
    
    return request.Approve();
  });

// ============================================
// POLICY 5: No Host Networking
// ============================================
When(a.Pod)
  .IsCreatedOrUpdated()
  .Validate((request) => {
    const pod = request.Raw;
    const exemptions = pod.metadata?.annotations?.["sekp.io/policy-exemptions"];
    
    if (pod.spec?.hostNetwork === true) {
      if (!exemptions?.includes("allow-host-network")) {
        return request.Deny("hostNetwork is not allowed without exemption");
      }
    }
    
    if (pod.spec?.hostPID === true) {
      if (!exemptions?.includes("allow-host-pid")) {
        return request.Deny("hostPID is not allowed without exemption");
      }
    }
    
    if (pod.spec?.hostIPC === true) {
      if (!exemptions?.includes("allow-host-ipc")) {
        return request.Deny("hostIPC is not allowed without exemption");
      }
    }
    
    return request.Approve();
  });

// ============================================
// POLICY 6: Image Registry Restrictions
// ============================================
const ALLOWED_REGISTRIES = [
  "docker.io/library/",
  "ghcr.io/",
  "quay.io/",
  "registry.k8s.io/",
  // Platform's own registry
  "registry.${DOMAIN}/",
];

When(a.Pod)
  .IsCreatedOrUpdated()
  .Validate((request) => {
    const pod = request.Raw;
    const exemptions = pod.metadata?.annotations?.["sekp.io/policy-exemptions"];
    
    if (exemptions?.includes("allow-any-registry")) {
      return request.Approve();
    }
    
    const allContainers = [
      ...(pod.spec?.containers || []),
      ...(pod.spec?.initContainers || []),
    ];
    
    for (const container of allContainers) {
      const image = container.image || "";
      const allowed = ALLOWED_REGISTRIES.some((reg) => image.startsWith(reg));
      
      if (!allowed) {
        return request.Deny(
          `Container '${container.name}' uses image from unauthorized registry: ${image}`
        );
      }
    }
    
    return request.Approve();
  });

// ============================================
// POLICY 7: Resource Limits Required
// ============================================
When(a.Pod)
  .IsCreatedOrUpdated()
  .Validate((request) => {
    const pod = request.Raw;
    
    // Skip system namespaces
    const ns = pod.metadata?.namespace || "";
    if (ns.startsWith("kube-") || ns === "istio-system" || ns === "pepr-system") {
      return request.Approve();
    }
    
    const allContainers = [
      ...(pod.spec?.containers || []),
      ...(pod.spec?.initContainers || []),
    ];
    
    for (const container of allContainers) {
      const resources = container.resources;
      
      if (!resources?.limits?.memory) {
        return request.Deny(
          `Container '${container.name}' must specify memory limits`
        );
      }
      
      if (!resources?.limits?.cpu) {
        return request.Deny(
          `Container '${container.name}' must specify CPU limits`
        );
      }
      
      if (!resources?.requests?.memory) {
        return request.Deny(
          `Container '${container.name}' must specify memory requests`
        );
      }
      
      if (!resources?.requests?.cpu) {
        return request.Deny(
          `Container '${container.name}' must specify CPU requests`
        );
      }
    }
    
    return request.Approve();
  });

// ============================================
// POLICY 8: Namespace Labels Required
// ============================================
When(a.Namespace)
  .IsCreatedOrUpdated()
  .Validate((request) => {
    const ns = request.Raw;
    const name = ns.metadata?.name || "";
    
    // Skip system namespaces
    if (name.startsWith("kube-") || name === "default") {
      return request.Approve();
    }
    
    const labels = ns.metadata?.labels || {};
    
    if (!labels["sekp.io/team"]) {
      return request.Deny("Namespace must have 'sekp.io/team' label");
    }
    
    if (!labels["sekp.io/environment"]) {
      return request.Deny("Namespace must have 'sekp.io/environment' label");
    }
    
    return request.Approve();
  });
```

#### 4.3.3 Policy Exemption CRD
```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: policyexemptions.sekp.io
spec:
  group: sekp.io
  names:
    kind: PolicyExemption
    listKind: PolicyExemptionList
    plural: policyexemptions
    singular: policyexemption
    shortNames:
      - pe
      - pexempt
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          required:
            - spec
          properties:
            spec:
              type: object
              required:
                - policies
                - reason
                - approver
                - expiresAt
              properties:
                policies:
                  type: array
                  items:
                    type: string
                    enum:
                      - allow-root
                      - allow-privileged
                      - allow-hostpath
                      - allow-host-network
                      - allow-host-pid
                      - allow-host-ipc
                      - allow-any-registry
                  description: List of policies to exempt
                selector:
                  type: object
                  properties:
                    matchLabels:
                      type: object
                      additionalProperties:
                        type: string
                reason:
                  type: string
                  minLength: 20
                  description: Detailed justification for exemption
                approver:
                  type: string
                  description: Email of person who approved
                expiresAt:
                  type: string
                  format: date-time
                  description: When this exemption expires
            status:
              type: object
              properties:
                state:
                  type: string
                  enum: [active, expired, revoked]
                lastChecked:
                  type: string
                  format: date-time
```

### 4.4 Storage Configuration

#### 4.4.1 Longhorn for Edge
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: longhorn-config
  namespace: storage-system
data:
  # Optimize for edge with limited storage
  default-replica-count: "2"  # 1 for single node
  default-data-locality: "best-effort"
  
  # Backup to S3-compatible storage
  backup-target: "s3://sekp-backups@us-east-1/"
  backup-target-credential-secret: "longhorn-backup-secret"
  
  # Recurring backups
  recurring-job-selector: '{"default": true}'
```

#### 4.4.2 Storage Classes
```yaml
# Fast storage for databases
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sekp-fast
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
  dataLocality: "best-effort"
  diskSelector: "ssd"
---
# Standard storage
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
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
---
# Backup-enabled storage
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sekp-backup
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "3"
  recurringJobs: '[{"name": "daily-backup", "task": "backup", "cron": "0 2 * * ?", "retain": 7}]'
```

---

## 5. CUSTOM RESOURCE DEFINITIONS

### 5.1 Application CRD (Developer Interface)

This is the PRIMARY interface developers will use. It abstracts away Istio, NetworkPolicies, and platform details.

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: applications.sekp.io
spec:
  group: sekp.io
  names:
    kind: Application
    listKind: ApplicationList
    plural: applications
    singular: application
    shortNames:
      - app
      - apps
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      subresources:
        status: {}
      additionalPrinterColumns:
        - name: Status
          type: string
          jsonPath: .status.state
        - name: URL
          type: string
          jsonPath: .status.url
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
      schema:
        openAPIV3Schema:
          type: object
          required:
            - spec
          properties:
            spec:
              type: object
              required:
                - image
                - port
              properties:
                # ============ DEPLOYMENT CONFIG ============
                image:
                  type: string
                  description: Container image to deploy
                  pattern: '^[a-z0-9.-]+(/[a-z0-9._-]+)+:[a-z0-9._-]+$'
                  
                port:
                  type: integer
                  minimum: 1
                  maximum: 65535
                  description: Port the application listens on
                  
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 100
                  default: 2
                  
                resources:
                  type: object
                  properties:
                    requests:
                      type: object
                      properties:
                        cpu:
                          type: string
                          default: "100m"
                        memory:
                          type: string
                          default: "128Mi"
                    limits:
                      type: object
                      properties:
                        cpu:
                          type: string
                          default: "500m"
                        memory:
                          type: string
                          default: "512Mi"
                          
                env:
                  type: array
                  items:
                    type: object
                    properties:
                      name:
                        type: string
                      value:
                        type: string
                      valueFrom:
                        type: object
                        properties:
                          secretKeyRef:
                            type: object
                            properties:
                              name:
                                type: string
                              key:
                                type: string
                                
                # ============ NETWORKING CONFIG ============
                networking:
                  type: object
                  properties:
                    # Public exposure
                    expose:
                      type: object
                      properties:
                        enabled:
                          type: boolean
                          default: true
                        subdomain:
                          type: string
                          description: "Subdomain for the app (e.g., 'myapp' -> myapp.example.com)"
                        paths:
                          type: array
                          items:
                            type: string
                          default: ["/"]
                          
                    # Authentication requirements
                    authentication:
                      type: object
                      properties:
                        required:
                          type: boolean
                          default: true
                          description: "Require authentication for all requests"
                        type:
                          type: string
                          enum: [user, machine, both]
                          default: user
                          description: "Type of authentication to accept"
                        publicPaths:
                          type: array
                          items:
                            type: string
                          description: "Paths that don't require auth (e.g., /health, /public)"
                        requiredRoles:
                          type: array
                          items:
                            type: string
                          description: "Keycloak roles required to access"
                        requiredGroups:
                          type: array
                          items:
                            type: string
                          description: "Keycloak groups required to access"
                          
                    # Egress (outbound) rules
                    egress:
                      type: array
                      items:
                        type: object
                        properties:
                          name:
                            type: string
                          type:
                            type: string
                            enum: [internal, external]
                          # For internal
                          service:
                            type: string
                            description: "service-name.namespace"
                          # For external
                          hosts:
                            type: array
                            items:
                              type: string
                          ports:
                            type: array
                            items:
                              type: integer
                              
                    # Ingress (inbound) rules - who can call this app
                    ingress:
                      type: array
                      items:
                        type: object
                        properties:
                          name:
                            type: string
                          from:
                            type: object
                            properties:
                              application:
                                type: string
                                description: "app-name.namespace"
                              serviceAccount:
                                type: string
                              namespace:
                                type: string
                          paths:
                            type: array
                            items:
                              type: string
                              
                # ============ STORAGE CONFIG ============
                storage:
                  type: array
                  items:
                    type: object
                    required:
                      - name
                      - mountPath
                      - size
                    properties:
                      name:
                        type: string
                      mountPath:
                        type: string
                      size:
                        type: string
                        pattern: '^[0-9]+[GMK]i$'
                      storageClass:
                        type: string
                        enum: [sekp-fast, sekp-standard, sekp-backup]
                        default: sekp-standard
                      accessMode:
                        type: string
                        enum: [ReadWriteOnce, ReadWriteMany]
                        default: ReadWriteOnce
                        
                # ============ SECRETS CONFIG ============
                secrets:
                  type: object
                  properties:
                    # Request Keycloak client credentials
                    keycloakClient:
                      type: object
                      properties:
                        enabled:
                          type: boolean
                          default: false
                        clientId:
                          type: string
                        secretName:
                          type: string
                          description: "Secret name to create with client credentials"
                    # External secrets to pull
                    externalSecrets:
                      type: array
                      items:
                        type: object
                        properties:
                          name:
                            type: string
                          provider:
                            type: string
                            enum: [vault, aws-secrets-manager, azure-keyvault]
                          path:
                            type: string
                            
                # ============ HEALTH CHECKS ============
                health:
                  type: object
                  properties:
                    path:
                      type: string
                      default: /health
                    port:
                      type: integer
                    initialDelaySeconds:
                      type: integer
                      default: 10
                    periodSeconds:
                      type: integer
                      default: 10
                      
                # ============ POLICY EXEMPTIONS ============
                policyExemptions:
                  type: array
                  items:
                    type: string
                    enum:
                      - allow-root
                      - allow-privileged
                      - allow-hostpath
                      - allow-host-network
                      - allow-any-registry
                  description: "Must be approved via PolicyExemption resource"
                  
            status:
              type: object
              properties:
                state:
                  type: string
                  enum: [Pending, Deploying, Running, Degraded, Failed]
                url:
                  type: string
                replicas:
                  type: object
                  properties:
                    desired:
                      type: integer
                    ready:
                      type: integer
                conditions:
                  type: array
                  items:
                    type: object
                    properties:
                      type:
                        type: string
                      status:
                        type: string
                      reason:
                        type: string
                      message:
                        type: string
                      lastTransitionTime:
                        type: string
                        format: date-time
                keycloakClient:
                  type: object
                  properties:
                    clientId:
                      type: string
                    created:
                      type: boolean
```

### 5.2 Example Application Manifest

```yaml
# Example: A simple web API that needs database access
apiVersion: sekp.io/v1
kind: Application
metadata:
  name: user-api
  namespace: apps-myteam
  labels:
    app.kubernetes.io/name: user-api
    app.kubernetes.io/component: backend
spec:
  image: registry.example.com/myteam/user-api:v1.2.3
  port: 8080
  replicas: 3
  
  resources:
    requests:
      cpu: "200m"
      memory: "256Mi"
    limits:
      cpu: "1000m"
      memory: "1Gi"
      
  env:
    - name: DATABASE_HOST
      value: "postgres.apps-myteam.svc.cluster.local"
    - name: DATABASE_PASSWORD
      valueFrom:
        secretKeyRef:
          name: user-api-db-creds
          key: password
          
  networking:
    expose:
      enabled: true
      subdomain: api
      paths:
        - /users
        - /auth
        
    authentication:
      required: true
      type: both  # Accept both user tokens and machine tokens
      publicPaths:
        - /health
        - /metrics
        - /public/*
      requiredRoles:
        - user-api-access
        
    # This app can call out to these services
    egress:
      - name: postgres
        type: internal
        service: postgres.apps-myteam
        
      - name: email-service
        type: external
        hosts:
          - api.sendgrid.com
        ports:
          - 443
          
    # These services can call this app
    ingress:
      - name: frontend
        from:
          application: frontend.apps-myteam
        paths:
          - /users/*
          
      - name: batch-processor
        from:
          serviceAccount: batch-processor
          namespace: apps-myteam
        paths:
          - /internal/*
          
  storage:
    - name: cache
      mountPath: /app/cache
      size: 1Gi
      storageClass: sekp-fast
      
  secrets:
    keycloakClient:
      enabled: true
      clientId: user-api-service
      secretName: user-api-keycloak-creds
      
  health:
    path: /health
    initialDelaySeconds: 15
    periodSeconds: 10
```

### 5.3 MachineClient CRD (For Non-Person Entities)

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: machineclients.sekp.io
spec:
  group: sekp.io
  names:
    kind: MachineClient
    listKind: MachineClientList
    plural: machineclients
    singular: machineclient
    shortNames:
      - mc
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          required:
            - spec
          properties:
            spec:
              type: object
              required:
                - clientId
                - authMethod
              properties:
                clientId:
                  type: string
                  pattern: '^[a-z0-9-]+$'
                  
                description:
                  type: string
                  
                authMethod:
                  type: string
                  enum:
                    - client-credentials  # OAuth2 client credentials grant
                    - mtls                # Mutual TLS with client certificate
                    - api-key             # Static API key (least preferred)
                    
                # For client-credentials
                oauth:
                  type: object
                  properties:
                    tokenLifetime:
                      type: integer
                      default: 3600
                    refreshTokenEnabled:
                      type: boolean
                      default: false
                    scopes:
                      type: array
                      items:
                        type: string
                        
                # For mTLS
                mtls:
                  type: object
                  properties:
                    certificateDuration:
                      type: string
                      default: "720h"  # 30 days
                    issuerRef:
                      type: object
                      properties:
                        name:
                          type: string
                        kind:
                          type: string
                          enum: [ClusterIssuer, Issuer]
                          
                # Permissions
                allowedApplications:
                  type: array
                  items:
                    type: object
                    properties:
                      name:
                        type: string
                      namespace:
                        type: string
                      paths:
                        type: array
                        items:
                          type: string
                      methods:
                        type: array
                        items:
                          type: string
                          enum: [GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS]
                          
                # Rate limiting
                rateLimit:
                  type: object
                  properties:
                    requestsPerSecond:
                      type: integer
                      default: 100
                    burstSize:
                      type: integer
                      default: 200
                      
            status:
              type: object
              properties:
                state:
                  type: string
                  enum: [Pending, Active, Suspended, Expired]
                secretName:
                  type: string
                certificateSecretName:
                  type: string
                lastRotated:
                  type: string
                  format: date-time
```

---

## 6. SECURITY REQUIREMENTS

### 6.1 Security Checklist

```yaml
# All of these MUST be implemented and verified

network_security:
  - All external traffic terminates at Istio Gateway
  - mTLS enforced for all internal traffic
  - No direct pod-to-pod communication without Istio
  - Egress traffic restricted to allow-list
  - NetworkPolicies as backup to Istio
  
authentication:
  - All human users authenticate via Keycloak
  - All machine clients use one of: client-credentials, mTLS, API keys
  - No anonymous access to any application by default
  - Session tokens are short-lived with secure rotation
  - MFA available and enforceable per-realm
  
authorization:
  - RBAC enforced at Kubernetes API level
  - Istio AuthorizationPolicy enforced at service level
  - Least-privilege by default
  - Explicit allow rules required (deny-all baseline)
  
container_security:
  - No root containers without exemption
  - No privileged containers without exemption
  - Read-only root filesystem enforced
  - Capabilities dropped (ALL)
  - No hostPath, hostNetwork, hostPID, hostIPC without exemption
  - Resource limits required
  - Seccomp profile enforced (RuntimeDefault minimum)
  
secrets_management:
  - No secrets in environment variables directly (use secretKeyRef)
  - Secrets encrypted at rest (Kubernetes encryption)
  - External secrets operator for external vaults
  - Secret rotation supported
  
supply_chain:
  - Image registries restricted to allow-list
  - Image signing verification (optional, future)
  - Vulnerability scanning (Trivy, optional)
  
audit_logging:
  - All API server requests logged
  - All Istio access logs retained
  - All authentication events logged
  - All policy violations logged
  - Logs shipped to central location
  
backup_recovery:
  - Automated daily backups
  - Backup encryption
  - Tested restore procedure
  - Cross-region backup (optional)
```

### 6.2 Defense in Depth Layers

```
Layer 1: Edge/Gateway
  - TLS termination
  - DDoS protection (rate limiting)
  - WAF rules (optional)
  - Geographic blocking (optional)

Layer 2: Authentication
  - Keycloak OIDC
  - JWT validation
  - mTLS for services

Layer 3: Authorization
  - Istio AuthorizationPolicy
  - Fine-grained path/method control
  - Role/group based access

Layer 4: Admission Control
  - PEPR policies
  - Prevent insecure configurations
  - Enforce standards

Layer 5: Runtime
  - Istio mTLS
  - NetworkPolicy (backup)
  - Seccomp/AppArmor
  - Read-only filesystem

Layer 6: Data
  - Encrypted at rest
  - Encrypted in transit
  - Backup encryption
```

---

## 7. POLICY ENFORCEMENT

### 7.1 Complete PEPR Policy Catalog

```typescript
// policies/index.ts - Main policy registration

import { PeprModule } from "pepr";
import { SecurityPolicies } from "./security-policies";
import { NetworkPolicies } from "./network-policies";
import { ResourcePolicies } from "./resource-policies";
import { NamespacePolicies } from "./namespace-policies";
import { Mutations } from "./mutations";

new PeprModule({
  uuid: "sekp-policies",
  capabilities: [
    SecurityPolicies,
    NetworkPolicies,
    ResourcePolicies,
    NamespacePolicies,
    Mutations,
  ],
});
```

```typescript
// policies/mutations.ts - Auto-apply security best practices

import { Capability, a } from "pepr";

export const Mutations = new Capability({
  name: "mutations",
  description: "Auto-apply security configurations",
  namespaces: [],
});

const { When } = Mutations;

// Auto-inject security labels
When(a.Pod)
  .IsCreated()
  .InNamespace(/^apps-/)
  .Mutate((request) => {
    const pod = request.Raw;
    
    // Ensure security annotations
    pod.metadata = pod.metadata || {};
    pod.metadata.annotations = pod.metadata.annotations || {};
    
    // Add pod security standard label
    pod.metadata.labels = pod.metadata.labels || {};
    pod.metadata.labels["pod-security.kubernetes.io/enforce"] = "restricted";
    
    // Ensure automountServiceAccountToken is false unless needed
    if (pod.spec?.automountServiceAccountToken === undefined) {
      pod.spec = pod.spec || {};
      pod.spec.automountServiceAccountToken = false;
    }
    
    return request;
  });

// Auto-add Istio sidecar annotations if missing
When(a.Pod)
  .IsCreated()
  .InNamespace(/^apps-/)
  .Mutate((request) => {
    const pod = request.Raw;
    
    pod.metadata = pod.metadata || {};
    pod.metadata.annotations = pod.metadata.annotations || {};
    
    // Ensure Istio proxy has limited resources
    if (!pod.metadata.annotations["sidecar.istio.io/proxyCPU"]) {
      pod.metadata.annotations["sidecar.istio.io/proxyCPU"] = "50m";
    }
    if (!pod.metadata.annotations["sidecar.istio.io/proxyMemory"]) {
      pod.metadata.annotations["sidecar.istio.io/proxyMemory"] = "64Mi";
    }
    
    return request;
  });
```

```typescript
// policies/network-policies.ts - Ensure NetworkPolicies exist

import { Capability, a, K8s, kind } from "pepr";

export const NetworkPolicies = new Capability({
  name: "network-policies",
  description: "Enforce network segmentation",
  namespaces: [],
});

const { When } = NetworkPolicies;

// When namespace is created, add default deny NetworkPolicy
When(a.Namespace)
  .IsCreated()
  .WithLabel("sekp.io/team")
  .Watch(async (ns) => {
    const name = ns.metadata?.name;
    if (!name || name.startsWith("kube-") || name === "default") {
      return;
    }
    
    // Create default deny-all NetworkPolicy
    await K8s(kind.NetworkPolicy).Apply({
      metadata: {
        name: "default-deny-all",
        namespace: name,
      },
      spec: {
        podSelector: {},
        policyTypes: ["Ingress", "Egress"],
        // Empty ingress/egress = deny all
        ingress: [],
        egress: [
          // Allow DNS
          {
            to: [
              {
                namespaceSelector: {
                  matchLabels: {
                    "kubernetes.io/metadata.name": "kube-system",
                  },
                },
              },
            ],
            ports: [
              { protocol: "UDP", port: 53 },
              { protocol: "TCP", port: 53 },
            ],
          },
        ],
      },
    });
  });
```

### 7.2 Policy Enforcement Levels

```yaml
policy_levels:
  # Level 1: Hard requirements - cannot be bypassed
  hard:
    - no-privileged-without-exemption
    - no-host-network-without-exemption
    - resource-limits-required
    - namespace-labels-required
    
  # Level 2: Default deny with exemption process
  exemptable:
    - no-root-containers
    - read-only-filesystem
    - drop-all-capabilities
    - registry-restrictions
    - no-hostpath
    
  # Level 3: Warnings only (soft enforcement)
  warn:
    - deprecated-api-versions
    - missing-pod-disruption-budget
    - single-replica-deployment

exemption_process:
  1. Developer creates PolicyExemption CR with justification
  2. Platform admin reviews and approves
  3. Exemption applied to specific workloads
  4. Exemption has expiration date
  5. Automatic alerts before expiration
  6. Regular audit of all exemptions
```

---

## 8. INSTALLATION & BOOTSTRAP

### 8.1 Installation Script Requirements

```bash
#!/usr/bin/env bash
# install.sh - Single command installation

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

# These can be overridden via environment variables
SEKP_DOMAIN="${SEKP_DOMAIN:-}"
SEKP_ENVIRONMENT="${SEKP_ENVIRONMENT:-edge}"  # edge, enterprise, dev
SEKP_K8S_DISTRIBUTION="${SEKP_K8S_DISTRIBUTION:-auto}"  # k3s, kind, eks, gke, aks, auto
SEKP_ADMIN_EMAIL="${SEKP_ADMIN_EMAIL:-}"
SEKP_ADMIN_PASSWORD="${SEKP_ADMIN_PASSWORD:-}"  # If not set, generate random
SEKP_INSTALL_DIR="${SEKP_INSTALL_DIR:-$HOME/.sekp}"
SEKP_TLS_MODE="${SEKP_TLS_MODE:-self-signed}"  # self-signed, letsencrypt, existing
SEKP_REGISTRY="${SEKP_REGISTRY:-}"  # Private registry if air-gapped

# ============================================
# PREFLIGHT CHECKS (run as unprivileged user)
# ============================================

preflight_checks() {
    echo "Running preflight checks..."
    
    # Check if running as root (we don't want that)
    if [[ $EUID -eq 0 ]]; then
        echo "ERROR: Do not run as root. Run as regular user with sudo access."
        exit 1
    fi
    
    # Check sudo access
    if ! sudo -n true 2>/dev/null; then
        echo "This script requires sudo access for some operations."
        echo "You may be prompted for your password."
        sudo -v
    fi
    
    # Check required tools
    local required_tools=("curl" "git")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            echo "ERROR: $tool is required but not installed."
            exit 1
        fi
    done
    
    # Check system resources
    local available_memory=$(free -g | awk '/^Mem:/{print $7}')
    local available_cpus=$(nproc)
    
    if [[ $available_memory -lt 6 ]]; then
        echo "WARNING: Less than 6GB RAM available. Minimum 8GB recommended."
    fi
    
    if [[ $available_cpus -lt 4 ]]; then
        echo "WARNING: Less than 4 CPUs available. Performance may be degraded."
    fi
    
    # Check disk space
    local available_disk=$(df -BG "$HOME" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [[ $available_disk -lt 40 ]]; then
        echo "ERROR: Less than 40GB disk space available."
        exit 1
    fi
    
    echo "Preflight checks passed."
}

# ============================================
# INTERACTIVE CONFIGURATION
# ============================================

configure_installation() {
    echo ""
    echo "=========================================="
    echo "SEKP Installation Configuration"
    echo "=========================================="
    echo ""
    
    # Domain
    if [[ -z "$SEKP_DOMAIN" ]]; then
        read -p "Enter your domain (e.g., example.com): " SEKP_DOMAIN
    fi
    
    # Admin email
    if [[ -z "$SEKP_ADMIN_EMAIL" ]]; then
        read -p "Enter admin email: " SEKP_ADMIN_EMAIL
    fi
    
    # Admin password
    if [[ -z "$SEKP_ADMIN_PASSWORD" ]]; then
        echo "Enter admin password (leave empty to generate):"
        read -s SEKP_ADMIN_PASSWORD
        if [[ -z "$SEKP_ADMIN_PASSWORD" ]]; then
            SEKP_ADMIN_PASSWORD=$(openssl rand -base64 24)
            echo "Generated password: $SEKP_ADMIN_PASSWORD"
            echo "SAVE THIS PASSWORD - it will not be shown again!"
        fi
    fi
    
    # Environment
    echo ""
    echo "Select environment:"
    echo "  1) edge      - Single node, minimal resources"
    echo "  2) enterprise - Multi-node HA"
    echo "  3) dev       - Local development (Kind)"
    read -p "Choice [1-3]: " env_choice
    case $env_choice in
        1) SEKP_ENVIRONMENT="edge" ;;
        2) SEKP_ENVIRONMENT="enterprise" ;;
        3) SEKP_ENVIRONMENT="dev" ;;
        *) SEKP_ENVIRONMENT="edge" ;;
    esac
    
    # TLS mode
    echo ""
    echo "Select TLS mode:"
    echo "  1) self-signed  - Self-signed certificates (dev/testing)"
    echo "  2) letsencrypt  - Let's Encrypt (requires public DNS)"
    echo "  3) existing     - Bring your own certificates"
    read -p "Choice [1-3]: " tls_choice
    case $tls_choice in
        1) SEKP_TLS_MODE="self-signed" ;;
        2) SEKP_TLS_MODE="letsencrypt" ;;
        3) SEKP_TLS_MODE="existing" ;;
        *) SEKP_TLS_MODE="self-signed" ;;
    esac
    
    # Summary
    echo ""
    echo "=========================================="
    echo "Configuration Summary"
    echo "=========================================="
    echo "Domain:      $SEKP_DOMAIN"
    echo "Admin Email: $SEKP_ADMIN_EMAIL"
    echo "Environment: $SEKP_ENVIRONMENT"
    echo "TLS Mode:    $SEKP_TLS_MODE"
    echo "=========================================="
    echo ""
    read -p "Proceed with installation? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Installation cancelled."
        exit 0
    fi
}

# ============================================
# KUBERNETES BOOTSTRAP
# ============================================

bootstrap_kubernetes() {
    echo "Bootstrapping Kubernetes cluster..."
    
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
            echo "Using existing cluster..."
            ;;
    esac
    
    # Wait for cluster to be ready
    echo "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
}

install_k3s() {
    echo "Installing K3s..."
    
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
}

install_kind() {
    echo "Installing Kind..."
    
    # Install Kind if not present
    if ! command -v kind &>/dev/null; then
        curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
        chmod +x ./kind
        sudo mv ./kind /usr/local/bin/kind
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
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
  - role: worker
  - role: worker
EOF
    
    kind create cluster --name sekp --config /tmp/kind-config.yaml
    
    export KUBECONFIG="$HOME/.kube/config"
}

# ============================================
# PLATFORM INSTALLATION
# ============================================

install_platform() {
    echo "Installing SEKP platform components..."
    
    # Create install directory
    mkdir -p "$SEKP_INSTALL_DIR"
    
    # Save configuration
    cat > "$SEKP_INSTALL_DIR/config.env" <<EOF
SEKP_DOMAIN=$SEKP_DOMAIN
SEKP_ENVIRONMENT=$SEKP_ENVIRONMENT
SEKP_ADMIN_EMAIL=$SEKP_ADMIN_EMAIL
SEKP_TLS_MODE=$SEKP_TLS_MODE
EOF
    
    # Install in order
    install_cert_manager
    install_istio
    install_pepr
    install_storage
    install_keycloak
    install_monitoring
    install_sekp_operator
    install_velero
    
    # Apply default configurations
    apply_default_policies
    apply_default_gateway
    
    # Final setup
    setup_initial_admin
}

install_cert_manager() {
    echo "Installing cert-manager..."
    
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.yaml
    
    kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s
    
    # Create issuers based on TLS mode
    case $SEKP_TLS_MODE in
        self-signed)
            kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: sekp-issuer
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
    name: sekp-issuer
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: sekp-ca-issuer
spec:
  ca:
    secretName: sekp-ca-secret
EOF
            ;;
        letsencrypt)
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
}

install_istio() {
    echo "Installing Istio..."
    
    # Install istioctl
    curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.21.0 sh -
    export PATH="$HOME/istio-1.21.0/bin:$PATH"
    
    # Install with custom profile
    istioctl install -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: sekp-istio
spec:
  profile: minimal
  meshConfig:
    accessLogFile: /dev/stdout
    enableTracing: true
    defaultConfig:
      holdApplicationUntilProxyStarts: true
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY
  components:
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          service:
            type: $([ "$SEKP_ENVIRONMENT" == "dev" ] && echo "NodePort" || echo "LoadBalancer")
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
  values:
    global:
      mtls:
        enabled: true
      proxy:
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
EOF
    
    kubectl wait --for=condition=Available deployment --all -n istio-system --timeout=300s
    
    # Enable strict mTLS
    kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
EOF
}

install_pepr() {
    echo "Installing PEPR..."
    
    # Install PEPR CLI
    npm install -g pepr
    
    # Create PEPR module
    mkdir -p "$SEKP_INSTALL_DIR/pepr"
    cd "$SEKP_INSTALL_DIR/pepr"
    
    # Initialize PEPR project
    cat > package.json <<EOF
{
  "name": "sekp-policies",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "build": "pepr build"
  },
  "dependencies": {
    "pepr": "^0.28.0"
  }
}
EOF
    
    npm install
    
    # Copy policy files (these would be generated/copied from templates)
    # ... policy files from section 7 ...
    
    # Build and deploy
    npx pepr build
    kubectl apply -f dist/
    
    cd -
}

install_storage() {
    echo "Installing storage solution..."
    
    if [[ "$SEKP_ENVIRONMENT" == "edge" || "$SEKP_ENVIRONMENT" == "enterprise" ]]; then
        # Install Longhorn
        kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.6.0/deploy/longhorn.yaml
        
        kubectl wait --for=condition=Available deployment --all -n longhorn-system --timeout=600s
        
        # Create storage classes
        kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sekp-standard
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
parameters:
  numberOfReplicas: "$([ "$SEKP_ENVIRONMENT" == "edge" ] && echo "1" || echo "2")"
  staleReplicaTimeout: "2880"
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sekp-fast
provisioner: driver.longhorn.io
allowVolumeExpansion: true
parameters:
  numberOfReplicas: "$([ "$SEKP_ENVIRONMENT" == "edge" ] && echo "1" || echo "2")"
  diskSelector: "ssd"
EOF
    else
        # Dev environment - use local path provisioner
        kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
    fi
}

install_keycloak() {
    echo "Installing Keycloak..."
    
    kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace keycloak istio-injection=enabled --overwrite
    
    # Install Keycloak operator
    kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/24.0.0/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
    kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/24.0.0/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml
    kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/24.0.0/kubernetes/kubernetes.yml -n keycloak
    
    # Wait for operator
    kubectl wait --for=condition=Available deployment keycloak-operator -n keycloak --timeout=300s
    
    # Create admin secret
    kubectl create secret generic keycloak-admin-secret -n keycloak \
        --from-literal=username=admin \
        --from-literal=password="$SEKP_ADMIN_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Deploy Keycloak instance
    kubectl apply -f - <<EOF
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: keycloak
spec:
  instances: $([ "$SEKP_ENVIRONMENT" == "edge" ] && echo "1" || echo "2")
  hostname:
    hostname: auth.$SEKP_DOMAIN
  http:
    tlsSecret: keycloak-tls
  db:
    vendor: $([ "$SEKP_ENVIRONMENT" == "dev" ] && echo "dev-file" || echo "postgres")
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: keycloak-tls
  namespace: keycloak
spec:
  secretName: keycloak-tls
  issuerRef:
    name: sekp-issuer
    kind: ClusterIssuer
  dnsNames:
    - auth.$SEKP_DOMAIN
EOF
    
    # Wait for Keycloak
    kubectl wait --for=condition=Ready keycloak keycloak -n keycloak --timeout=600s
    
    # Import platform realm
    # ... realm configuration from section 4.2 ...
}

install_monitoring() {
    echo "Installing monitoring stack..."
    
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # Install Prometheus + Grafana via Helm
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    
    helm install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --set prometheus.prometheusSpec.resources.requests.cpu=100m \
        --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
        --set grafana.resources.requests.cpu=50m \
        --set grafana.resources.requests.memory=128Mi \
        --set alertmanager.enabled=false \
        --wait
    
    # Install Loki for logs
    helm repo add grafana https://grafana.github.io/helm-charts
    helm install loki grafana/loki-stack \
        --namespace monitoring \
        --set promtail.enabled=true \
        --set grafana.enabled=false \
        --wait
}

install_sekp_operator() {
    echo "Installing SEKP operator..."
    
    kubectl create namespace sekp-system --dry-run=client -o yaml | kubectl apply -f -
    
    # The operator would be built and deployed here
    # This handles the Application CRD, MachineClient CRD, etc.
    
    # Apply CRDs
    kubectl apply -f "$SEKP_INSTALL_DIR/crds/"
    
    # Deploy operator
    kubectl apply -f "$SEKP_INSTALL_DIR/operator/"
}

install_velero() {
    echo "Installing Velero for backups..."
    
    # Install Velero CLI
    curl -fsSL -o velero.tar.gz https://github.com/vmware-tanzu/velero/releases/download/v1.13.0/velero-v1.13.0-linux-amd64.tar.gz
    tar -xzf velero.tar.gz
    sudo mv velero-v1.13.0-linux-amd64/velero /usr/local/bin/
    rm -rf velero.tar.gz velero-v1.13.0-linux-amd64
    
    # Install Velero in cluster (with local storage for dev, S3 for prod)
    # Configuration depends on environment
}

apply_default_policies() {
    echo "Applying default security policies..."
    
    # Default deny all
    kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: istio-system
spec: {}
---
# Allow kube-system
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-kube-system
  namespace: kube-system
spec:
  rules:
    - {}
EOF
}

apply_default_gateway() {
    echo "Configuring default gateway..."
    
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
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
        - "*.$SEKP_DOMAIN"
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*.$SEKP_DOMAIN"
      tls:
        httpsRedirect: true
---
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
  dnsNames:
    - "*.$SEKP_DOMAIN"
    - $SEKP_DOMAIN
EOF
}

setup_initial_admin() {
    echo ""
    echo "=========================================="
    echo "SEKP Installation Complete!"
    echo "=========================================="
    echo ""
    echo "Platform Admin UI:  https://admin.$SEKP_DOMAIN"
    echo "Keycloak Admin:     https://auth.$SEKP_DOMAIN"
    echo "Grafana:            https://grafana.$SEKP_DOMAIN"
    echo ""
    echo "Admin Credentials:"
    echo "  Username: admin"
    echo "  Password: $SEKP_ADMIN_PASSWORD"
    echo ""
    echo "Configuration saved to: $SEKP_INSTALL_DIR/config.env"
    echo ""
    
    # Save credentials securely
    cat > "$SEKP_INSTALL_DIR/credentials" <<EOF
KEYCLOAK_ADMIN_USER=admin
KEYCLOAK_ADMIN_PASSWORD=$SEKP_ADMIN_PASSWORD
EOF
    chmod 600 "$SEKP_INSTALL_DIR/credentials"
}

# ============================================
# MAIN
# ============================================

main() {
    echo "=========================================="
    echo "SEKP - SecureEdge Kubernetes Platform"
    echo "=========================================="
    
    preflight_checks
    configure_installation
    bootstrap_kubernetes
    install_platform
    
    echo ""
    echo "Installation complete! Run 'sekp status' to check platform health."
}

main "$@"
```

---

## 9. TESTING REQUIREMENTS

### 9.1 Test Categories

```yaml
testing_requirements:
  unit_tests:
    coverage_target: 80%
    frameworks:
      - TypeScript: jest
      - Go: go test
    scope:
      - PEPR policies
      - SEKP operator logic
      - CRD validation
      
  integration_tests:
    frameworks:
      - Kubernetes: kind + Ginkgo
      - E2E: Playwright/Cypress
    scope:
      - Application deployment via CRD
      - Authentication flows
      - Policy enforcement
      - Network policies
      - Storage provisioning
      
  security_tests:
    tools:
      - kube-bench: CIS benchmarks
      - trivy: Image vulnerabilities
      - kubescape: NSA/CISA guidelines
      - checkov: IaC scanning
    scope:
      - RBAC configuration
      - Network segmentation
      - Secret handling
      - Container security
      
  performance_tests:
    tools:
      - k6: Load testing
      - Prometheus: Metrics
    scope:
      - Auth latency (<100ms)
      - Request throughput
      - Resource consumption
      - Startup time
      
  chaos_tests:
    tools:
      - Litmus
      - Chaos Mesh
    scope:
      - Pod failures
      - Network partitions
      - Control plane resilience
```

### 9.2 Test Specifications

```typescript
// tests/e2e/application-deployment.spec.ts

import { describe, it, expect, beforeAll, afterAll } from "@jest/globals";
import { KubeConfig, CustomObjectsApi, AppsV1Api } from "@kubernetes/client-node";

describe("Application CRD", () => {
  let k8sApi: CustomObjectsApi;
  let appsApi: AppsV1Api;
  const testNamespace = "test-apps";
  
  beforeAll(async () => {
    const kc = new KubeConfig();
    kc.loadFromDefault();
    k8sApi = kc.makeApiClient(CustomObjectsApi);
    appsApi = kc.makeApiClient(AppsV1Api);
    
    // Create test namespace
    // ...
  });
  
  afterAll(async () => {
    // Cleanup
  });
  
  describe("Basic Deployment", () => {
    it("should create Deployment from Application CR", async () => {
      const app = {
        apiVersion: "sekp.io/v1",
        kind: "Application",
        metadata: {
          name: "test-app",
          namespace: testNamespace,
        },
        spec: {
          image: "nginx:latest",
          port: 80,
          replicas: 2,
        },
      };
      
      await k8sApi.createNamespacedCustomObject(
        "sekp.io",
        "v1",
        testNamespace,
        "applications",
        app
      );
      
      // Wait for deployment
      await waitForDeployment("test-app", testNamespace, 60000);
      
      const deployment = await appsApi.readNamespacedDeployment(
        "test-app",
        testNamespace
      );
      
      expect(deployment.body.spec?.replicas).toBe(2);
    });
    
    it("should create VirtualService for exposed app", async () => {
      // Verify Istio VirtualService was created
    });
    
    it("should create AuthorizationPolicy", async () => {
      // Verify Istio AuthorizationPolicy was created
    });
  });
  
  describe("Authentication Enforcement", () => {
    it("should redirect unauthenticated users to Keycloak", async () => {
      const response = await fetch(`https://test-app.${process.env.SEKP_DOMAIN}`);
      expect(response.status).toBe(302);
      expect(response.headers.get("location")).toContain("auth.");
    });
    
    it("should allow access with valid JWT", async () => {
      const token = await getValidJWT();
      const response = await fetch(`https://test-app.${process.env.SEKP_DOMAIN}`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      expect(response.status).toBe(200);
    });
    
    it("should reject expired JWT", async () => {
      const expiredToken = await getExpiredJWT();
      const response = await fetch(`https://test-app.${process.env.SEKP_DOMAIN}`, {
        headers: { Authorization: `Bearer ${expiredToken}` },
      });
      expect(response.status).toBe(401);
    });
  });
  
  describe("Machine Client Authentication", () => {
    it("should allow machine client with valid credentials", async () => {
      const machineToken = await getMachineClientToken();
      const response = await fetch(`https://test-app.${process.env.SEKP_DOMAIN}/api/data`, {
        headers: { Authorization: `Bearer ${machineToken}` },
      });
      expect(response.status).toBe(200);
    });
    
    it("should allow mTLS authenticated requests", async () => {
      const response = await fetchWithClientCert(
        `https://test-app.${process.env.SEKP_DOMAIN}/api/data`,
        clientCert,
        clientKey
      );
      expect(response.status).toBe(200);
    });
  });
});
```

```typescript
// tests/e2e/policy-enforcement.spec.ts

describe("Policy Enforcement", () => {
  describe("Container Security Policies", () => {
    it("should reject pod running as root", async () => {
      const pod = {
        apiVersion: "v1",
        kind: "Pod",
        metadata: { name: "root-pod", namespace: "test-apps" },
        spec: {
          containers: [{
            name: "test",
            image: "nginx",
            securityContext: {
              runAsUser: 0,
            },
          }],
        },
      };
      
      await expect(createPod(pod)).rejects.toThrow(/runAsNonRoot/);
    });
    
    it("should reject privileged container", async () => {
      // ...
    });
    
    it("should allow pod with proper security context", async () => {
      const pod = {
        apiVersion: "v1",
        kind: "Pod",
        metadata: { name: "secure-pod", namespace: "test-apps" },
        spec: {
          containers: [{
            name: "test",
            image: "nginx",
            securityContext: {
              runAsNonRoot: true,
              runAsUser: 1000,
              allowPrivilegeEscalation: false,
              readOnlyRootFilesystem: true,
              capabilities: { drop: ["ALL"] },
            },
            resources: {
              limits: { cpu: "100m", memory: "128Mi" },
              requests: { cpu: "50m", memory: "64Mi" },
            },
          }],
        },
      };
      
      const result = await createPod(pod);
      expect(result.status.phase).toBe("Running");
    });
    
    it("should allow exempted pod to run as root", async () => {
      // First create PolicyExemption
      // Then create pod with annotation referencing exemption
    });
  });
  
  describe("Network Policies", () => {
    it("should block egress to non-allowed services", async () => {
      // Deploy pod and try to curl external service
    });
    
    it("should allow egress to declared dependencies", async () => {
      // ...
    });
  });
});
```

```bash
# tests/security/run-security-scan.sh

#!/bin/bash
set -e

echo "Running security scans..."

# CIS Benchmarks
echo "=== CIS Kubernetes Benchmarks ==="
kube-bench run --targets node,master,controlplane,policies

# NSA/CISA Guidelines
echo "=== Kubescape Security Scan ==="
kubescape scan framework nsa --exclude-namespaces kube-system

# Image Vulnerabilities
echo "=== Container Image Scan ==="
for ns in $(kubectl get ns -l sekp.io/team -o jsonpath='{.items[*].metadata.name}'); do
  for pod in $(kubectl get pods -n $ns -o jsonpath='{.items[*].metadata.name}'); do
    for container in $(kubectl get pod $pod -n $ns -o jsonpath='{.spec.containers[*].image}'); do
      echo "Scanning: $container"
      trivy image --severity HIGH,CRITICAL "$container"
    done
  done
done

# RBAC Analysis
echo "=== RBAC Security Analysis ==="
kubectl-who-can create pods --all-namespaces
kubectl-who-can create secrets --all-namespaces

echo "Security scans complete."
```

### 9.3 Test Matrix

```yaml
test_matrix:
  environments:
    - name: kind-single
      nodes: 1
      purpose: Fast CI validation
      
    - name: kind-ha
      nodes: 3
      purpose: HA testing
      
    - name: k3s-edge
      nodes: 1
      purpose: Edge simulation
      
    - name: eks-production
      nodes: 3
      purpose: Cloud validation
      
  test_suites:
    smoke:
      duration: 5min
      runs_on: [kind-single]
      tests:
        - platform-health
        - basic-deployment
        - auth-redirect
        
    integration:
      duration: 30min
      runs_on: [kind-ha]
      tests:
        - all-unit-tests
        - application-crd
        - authentication-flows
        - policy-enforcement
        - network-policies
        
    security:
      duration: 45min
      runs_on: [kind-ha, k3s-edge]
      tests:
        - cis-benchmarks
        - image-scanning
        - penetration-tests
        
    performance:
      duration: 60min
      runs_on: [eks-production]
      tests:
        - load-testing
        - latency-benchmarks
        - resource-usage
        
    chaos:
      duration: 120min
      runs_on: [eks-production]
      tests:
        - pod-kill
        - network-partition
        - node-drain
```

---

## 10. DOCUMENTATION REQUIREMENTS

### 10.1 Documentation Structure

```
docs/
├── getting-started/
│   ├── installation.md
│   ├── quick-start.md
│   ├── first-application.md
│   └── troubleshooting.md
│
├── architecture/
│   ├── overview.md
│   ├── security-model.md
│   ├── authentication-flows.md
│   ├── network-architecture.md
│   └── storage-architecture.md
│
├── developer-guide/
│   ├── deploying-applications.md
│   ├── application-crd-reference.md
│   ├── machine-clients.md
│   ├── secrets-management.md
│   ├── debugging.md
│   └── examples/
│       ├── simple-web-app.md
│       ├── api-with-database.md
│       ├── microservices.md
│       └── external-integrations.md
│
├── operator-guide/
│   ├── day-two-operations.md
│   ├── monitoring.md
│   ├── backup-restore.md
│   ├── upgrades.md
│   ├── scaling.md
│   └── disaster-recovery.md
│
├── security/
│   ├── security-policies.md
│   ├── policy-exemptions.md
│   ├── audit-logging.md
│   ├── incident-response.md
│   └── compliance.md
│
├── reference/
│   ├── crds/
│   │   ├── application.md
│   │   ├── machine-client.md
│   │   └── policy-exemption.md
│   ├── cli-reference.md
│   ├── configuration-reference.md
│   └── api-reference.md
│
└── contributing/
    ├── development-setup.md
    ├── testing.md
    ├── code-style.md
    └── releasing.md
```

### 10.2 Key Documentation Content

```markdown
# Developer Quick Start (docs/getting-started/quick-start.md)

## Deploying Your First Application

### Prerequisites
- Access to the SEKP cluster (kubeconfig configured)
- Your team's namespace created (e.g., `apps-myteam`)
- Container image pushed to allowed registry

### Step 1: Create Application Manifest

Create a file `my-app.yaml`:

apiVersion: sekp.io/v1
kind: Application
metadata:
  name: my-web-app
  namespace: apps-myteam
spec:
  image: registry.example.com/myteam/my-web-app:v1.0.0
  port: 8080
  replicas: 2
  
  networking:
    expose:
      enabled: true
      subdomain: myapp  # Creates myapp.example.com
      
    authentication:
      required: true
      publicPaths:
        - /health
        - /public/*
        
  resources:
    requests:
      cpu: "100m"
      memory: "128Mi"
    limits:
      cpu: "500m"
      memory: "512Mi"

### Step 2: Apply the Manifest

kubectl apply -f my-app.yaml

### Step 3: Check Status

kubectl get app my-web-app -n apps-myteam

Output:

NAME         STATUS    URL                        AGE
my-web-app   Running   https://myapp.example.com  2m

### Step 4: Access Your Application

Navigate to `https://myapp.example.com`. You'll be redirected to login via Keycloak.

## What Happened Behind the Scenes?

When you created the Application resource, SEKP automatically:

1. Created a Deployment with security-hardened pods
2. Created a Service
3. Created an Istio VirtualService for routing
4. Created an Istio AuthorizationPolicy requiring authentication
5. Configured Keycloak integration for OIDC
6. Created NetworkPolicies for your namespace
7. Set up health checks and readiness probes

You didn't need to understand Istio, Keycloak, or NetworkPolicies!
```

---

## 11. DIRECTORY STRUCTURE

```
sekp/
├── cmd/
│   ├── sekp-operator/        # Main operator binary
│   │   └── main.go
│   └── sekp-cli/             # CLI tool
│       └── main.go
│
├── pkg/
│   ├── apis/                 # CRD types
│   │   └── sekp.io/
│   │       └── v1/
│   │           ├── application_types.go
│   │           ├── machineclient_types.go
│   │           └── policyexemption_types.go
│   │
│   ├── controllers/          # Kubernetes controllers
│   │   ├── application/
│   │   ├── machineclient/
│   │   └── policyexemption/
│   │
│   ├── keycloak/            # Keycloak client library
│   ├── istio/               # Istio resource generation
│   └── webhook/             # Admission webhooks
│
├── pepr/                    # PEPR policies
│   ├── package.json
│   ├── pepr.ts
│   └── policies/
│       ├── security-policies.ts
│       ├── network-policies.ts
│       ├── resource-policies.ts
│       └── mutations.ts
│
├── deploy/                  # Deployment manifests
│   ├── crds/
│   ├── operator/
│   ├── istio/
│   ├── keycloak/
│   ├── pepr/
│   ├── monitoring/
│   └── storage/
│
├── install/                 # Installation scripts
│   ├── install.sh
│   ├── uninstall.sh
│   └── upgrade.sh
│
├── tests/
│   ├── unit/
│   ├── integration/
│   ├── e2e/
│   └── security/
│
├── docs/
│   └── ... (as defined above)
│
├── examples/
│   ├── applications/
│   ├── machine-clients/
│   └── policy-exemptions/
│
├── Makefile
├── Dockerfile
├── go.mod
├── go.sum
└── README.md
```

---

## 12. IMPLEMENTATION ORDER

### Phase 1: Foundation (Week 1-2)
```
1. Project scaffolding and repository setup
2. CRD definitions and types
3. Basic install script with K3s/Kind bootstrap
4. cert-manager installation
5. Istio installation with basic configuration
6. Basic Gateway setup
```

### Phase 2: Identity (Week 3-4)
```
1. Keycloak deployment
2. Platform realm configuration
3. Istio-Keycloak OIDC integration
4. RequestAuthentication resources
5. Basic AuthorizationPolicy (deny-all + allow patterns)
6. Token validation testing
```

### Phase 3: Policy Engine (Week 5-6)
```
1. PEPR project setup
2. Core security policies implementation
3. Mutation policies
4. PolicyExemption CRD and controller
5. Policy testing framework
```

### Phase 4: Application CRD (Week 7-9)
```
1. Application CRD definition
2. Application controller (creates Deployment, Service)
3. Istio resource generation (VirtualService, AuthorizationPolicy)
4. Keycloak client provisioning
5. Status updates and conditions
6. Integration testing
```

### Phase 5: Machine Clients (Week 10-11)
```
1. MachineClient CRD definition
2. OAuth2 client credentials flow
3. mTLS certificate provisioning
4. API key management
5. Integration with Istio authorization
```

### Phase 6: Storage & Observability (Week 12-13)
```
1. Longhorn installation and configuration
2. Storage classes
3. Prometheus/Grafana setup
4. Loki for logging
5. Dashboard creation
6. Alerting rules
```

### Phase 7: Operations (Week 14-15)
```
1. Velero backup/restore
2. Upgrade procedures
3. sekp CLI tool
4. Day-2 operations documentation
```

### Phase 8: Testing & Hardening (Week 16-17)
```
1. Complete E2E test suite
2. Security scanning integration
3. Performance testing
4. Chaos testing
5. Documentation finalization
```

### Phase 9: Release (Week 18)
```
1. Final testing
2. Release automation
3. Public documentation
4. Example applications
```

---

## CRITICAL SUCCESS CRITERIA

The implementation is considered complete when:

1. **Single Command Install**: `./install.sh` successfully deploys the entire platform
2. **No Root Required**: Installation runs as unprivileged user (sudo only when needed)
3. **All Traffic Authenticated**: No path to any application without authentication
4. **Policy Enforcement Working**: Cannot deploy insecure pods without exemption
5. **Developer CRD Working**: Can deploy application using only Application CR
6. **Machine Clients Working**: External systems can authenticate via OAuth2/mTLS
7. **All Tests Passing**: Unit, integration, e2e, and security tests pass
8. **Documentation Complete**: All docs written and reviewed
9. **Edge Deployment Validated**: Works on single-node K3s with 4CPU/8GB
10. **Enterprise Deployment Validated**: Works on multi-node cluster with HA

---

## NOTES FOR CLAUDE CODE

When implementing this project:

1. **Start with the install script** - Get a working cluster first
2. **Build incrementally** - Each phase should be testable independently  
3. **Write tests alongside code** - Don't defer testing
4. **Document as you go** - Write docs with implementation
5. **Security first** - Never compromise on security defaults
6. **Keep it simple** - Prefer simple solutions over complex ones
7. **Make it observable** - Add logging and metrics everywhere
8. **Handle errors gracefully** - Provide clear error messages
9. **Use existing tools** - Don't reinvent the wheel
10. **Think about upgrades** - Design for future changes

Remember: This platform will host production workloads. Security and reliability are paramount.
