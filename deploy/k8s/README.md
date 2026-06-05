# Kubernetes Deployment — Core Wallet

> Kubernetes manifests for deploying the Core Wallet service.
> Supports **AWS EKS** and **on-premise** clusters via Kustomize overlays.

## Directory Structure

```
deploy/k8s/
├── README.md                          ← this file
├── base/                              ← shared manifests (common to all envs)
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── serviceaccount.yaml
│   ├── configmap.yaml
│   ├── secret.yaml                    ← placeholder (use ExternalSecrets/Vault in prod)
│   ├── deployment.yaml                ← wallet-service + PgBouncer sidecar
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml                       ← Horizontal Pod Autoscaler
│   ├── pdb.yaml                       ← Pod Disruption Budget (minAvailable: 2)
│   └── networkpolicy.yaml             ← least-privilege network rules
│
└── overlays/
    ├── aws-eks/                       ← AWS EKS production
    │   ├── kustomization.yaml         ← ALB Ingress, IRSA, RDS endpoint
    │   ├── resources-patch.yaml
    │   └── hpa-patch.yaml
    │
    └── on-premise/                    ← On-premise / bare-metal K8s
        ├── kustomization.yaml         ← nginx ingress, in-cluster PG
        ├── postgres-statefulset.yaml  ← PG17 StatefulSet (single-primary)
        ├── resources-patch.yaml
        └── hpa-patch.yaml
```

## Quick Start

### AWS EKS

```bash
# Prerequisites: EKS cluster + ALB controller + ExternalSecrets operator

# Preview
kubectl kustomize deploy/k8s/overlays/aws-eks

# Deploy
kubectl apply -k deploy/k8s/overlays/aws-eks

# Check rollout
kubectl -n wallet rollout status deployment/wallet-service
kubectl -n wallet get pods -l app.kubernetes.io/name=wallet-service
```

### On-Premise

```bash
# Prerequisites: K8s cluster + nginx ingress + StorageClass "fast-ssd"

# Preview
kubectl kustomize deploy/k8s/overlays/on-premise

# Deploy (includes PostgreSQL StatefulSet)
kubectl apply -k deploy/k8s/overlays/on-premise

# Load DB schema (first time)
kubectl -n wallet exec -it postgres-primary-0 -- \
  psql -U postgres -d wallet -f /docker-entrypoint-initdb.d/01-schema.sql

# Check
kubectl -n wallet get all
```

## Architecture Comparison

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              AWS EKS                                              │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  Internet → ALB (AWS LB Controller) → wallet-service Pods (PgBouncer sidecar)   │
│                                                    ↓                             │
│                                          RDS PostgreSQL 17                       │
│                                          (managed, multi-AZ)                     │
│                                                                                  │
│  Secrets: AWS Secrets Manager + ExternalSecrets Operator                         │
│  Monitoring: CloudWatch Container Insights + OTel → X-Ray                       │
│  Storage: EBS gp3 (managed by RDS)                                              │
│  Auth: IRSA (IAM Role for Service Account)                                      │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────┐
│                           On-Premise                                              │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  LB (F5/HAProxy/MetalLB) → nginx Ingress → wallet-service Pods (PgBouncer)     │
│                                                    ↓                             │
│                                     PostgreSQL 17 StatefulSet                    │
│                                     (or external PG cluster via Patroni)         │
│                                                                                  │
│  Secrets: HashiCorp Vault + vault-secrets-operator (or sealed-secrets)           │
│  Monitoring: Prometheus + Grafana + OTel Collector                               │
│  Storage: Local NVMe / Ceph RBD / NetApp (StorageClass: fast-ssd)               │
│  Auth: K8s RBAC + network policies                                               │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Pod Architecture

```
┌─── Pod (wallet-service) ────────────────────────────────────────────────┐
│                                                                          │
│  ┌────────────────────────────┐    ┌─────────────────────────────────┐  │
│  │   wallet-service container │    │    PgBouncer sidecar            │  │
│  │                            │    │                                  │  │
│  │   :8080 (HTTP API)         │───▶│   :6432 (transaction pooling)   │  │
│  │                            │    │                                  │  │
│  │   • Go/Gin                 │    │   • pool_mode = transaction      │  │
│  │   • Audit GUC per-TX       │    │   • 16 server conns             │  │
│  │   • OTel tracing           │    │   • SCRAM-SHA-256               │  │
│  │   • EOD scheduler (1 pod)  │    │                                  │  │
│  │                            │    │          ┌───────────────────┐   │  │
│  │   Probes:                  │    │          │  → PostgreSQL     │   │  │
│  │     liveness  /healthz     │    │          │    :5432          │   │  │
│  │     readiness /healthz     │    │          └───────────────────┘   │  │
│  │     startup   /healthz     │    │                                  │  │
│  └────────────────────────────┘    └─────────────────────────────────┘  │
│                                                                          │
│  SecurityContext: runAsNonRoot, uid=65534                                │
│  TopologySpread: maxSkew=1 per zone                                      │
│  PDB: minAvailable=2                                                     │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## Sizing by TPS

| TPS | Pods (min–max) | CPU/Pod | Mem/Pod | PgBouncer pool | DB Size |
|-----|:---:|:---:|:---:|:---:|:---:|
| 100 | 1–2 | 250m | 256Mi | 8 | db.t4g.medium / 2 vCPU bare-metal |
| 500 | 2–4 | 500m | 512Mi | 12 | db.r6g.medium / 4 vCPU bare-metal |
| 1,000 | 2–6 | 500m | 512Mi | 16 | db.r6g.large / 4 vCPU bare-metal |
| 2,000 | 3–10 | 1000m | 1Gi | 16 | db.r6g.xlarge / 8 vCPU bare-metal |
| 5,000 | 6–15 | 1000m | 1Gi | 20 | db.r6g.2xlarge / 16 vCPU bare-metal |
| 10,000 | 10–30 | 2000m | 2Gi | 24 | db.r6g.4xlarge / 32 vCPU bare-metal |

### Node Sizing Recommendations

**AWS EKS (Graviton):**
| TPS Target | Node Type | Node Count | Notes |
|:---:|:---:|:---:|:---|
| ≤ 1,000 | m6g.large (2 vCPU, 8 GB) | 3 | Cost-optimized |
| 2,000 | m6g.xlarge (4 vCPU, 16 GB) | 3–5 | Design target |
| 5,000 | m6g.2xlarge (8 vCPU, 32 GB) | 4–6 | Peak traffic |
| 10,000 | m6g.2xlarge | 8–12 | + Cluster Autoscaler |

**On-Premise (bare-metal / VM):**
| TPS Target | Node Spec | Node Count | Notes |
|:---:|:---:|:---:|:---|
| ≤ 1,000 | 4 vCPU, 16 GB, NVMe | 3 | Minimal HA |
| 2,000 | 8 vCPU, 32 GB, NVMe | 3–4 | Design target |
| 5,000 | 8 vCPU, 32 GB, NVMe | 5–8 | + dedicated DB nodes |
| 10,000 | 16 vCPU, 64 GB, NVMe | 8–12 | Dedicated DB cluster |

## Secret Management

### AWS EKS — ExternalSecrets Operator

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: wallet-db-credentials
  namespace: wallet
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: wallet-db-credentials
  data:
    - secretKey: DB_DSN
      remoteRef:
        key: core-wallet-staging/rds/wallet-app
        property: dsn
```

### On-Premise — Vault

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: wallet-db-credentials
  namespace: wallet
spec:
  type: kv-v2
  mount: secret
  path: core-wallet/db
  destination:
    name: wallet-db-credentials
    create: true
```

## Observability

The service exports OTel traces and structured JSON logs.

**AWS EKS:**
- Traces → OTel Collector → X-Ray / Tempo
- Logs → CloudWatch Container Insights (via Fluent Bit DaemonSet)
- Metrics → CloudWatch (Container Insights) or Prometheus (AMP)

**On-Premise:**
- Traces → OTel Collector → Tempo / Jaeger
- Logs → OTel Collector → Loki / Elasticsearch
- Metrics → Prometheus → Grafana dashboards

```bash
# Install OTel collector (Helm)
helm install otel-collector open-telemetry/opentelemetry-collector \
  --namespace observability --create-namespace \
  -f deploy/k8s/observability/otel-values.yaml
```

## Database Options

### AWS EKS → RDS PostgreSQL (recommended)

Managed service. Provisioned by Terraform (`deploy/terraform/modules/rds/`).
wallet-service pods connect via PgBouncer sidecar → RDS endpoint (private subnet).

### On-Premise → Options (pick one):

| Option | Complexity | HA | Recommendation |
|--------|:---:|:---:|:---|
| StatefulSet (included) | Low | None | Dev/staging only |
| CloudNativePG Operator | Medium | Auto-failover | **Recommended for prod** |
| Patroni + etcd | High | Leader election | Battle-tested, more ops |
| External PG cluster | N/A | Depends | If you already have DBA-managed PG |

For production on-premise, install CloudNativePG:

```bash
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.23/releases/cnpg-1.23.0.yaml

# Then replace the StatefulSet with a CloudNativePG Cluster resource
```

## CI/CD Integration

See `.github/workflows/cd-k8s.yml`. Flow:

```
git push master → build images → kustomize set image → kubectl apply (staging)
git tag v1.x.y → build images → kustomize set image → kubectl apply (production)
```

For on-premise without GitHub connectivity:
1. Use a self-hosted runner with `kubeconfig` access
2. Or: push images to internal registry, ArgoCD watches and syncs

### ArgoCD (alternative to kubectl apply)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: wallet-service
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/Core.git
    targetRevision: HEAD
    path: deploy/k8s/overlays/aws-eks  # or on-premise
  destination:
    server: https://kubernetes.default.svc
    namespace: wallet
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```
