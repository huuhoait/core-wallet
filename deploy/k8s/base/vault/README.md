# Secrets Management — HashiCorp Vault

> Zero-trust secrets for Core Wallet. Same approach works on AWS EKS and on-premise.
> No hardcoded credentials — Vault Secrets Operator (VSO) syncs secrets into K8s.

## Architecture

```
┌─── Vault (vault namespace) ─────────────────────────────────────────────┐
│                                                                          │
│  KV v2 Engine: secret/core-wallet/                                       │
│    ├── db/wallet-app      → {username, password, DB_DSN}                │
│    ├── db/wallet-pii-ro   → {username, password, DB_PII_DSN}            │
│    ├── db/wallet-eod      → {username, password, EOD_DSN}               │
│    ├── otel               → {OTEL_EXPORTER_OTLP_ENDPOINT}              │
│    └── pii-dek            → {PII_DEK}                                   │
│                                                                          │
│  Auth: Kubernetes method (bound to SA wallet-service in ns wallet)       │
│  Policy: wallet-service (read-only on core-wallet/*)                     │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
         │
         │  Vault Secrets Operator (VSO)
         │  watches VaultStaticSecret CRDs
         ▼
┌─── wallet namespace ────────────────────────────────────────────────────┐
│                                                                          │
│  K8s Secret: wallet-db-credentials   ← synced from Vault (refresh 1h)  │
│  K8s Secret: wallet-pii-credentials  ← synced from Vault               │
│  K8s Secret: wallet-eod-credentials  ← synced from Vault               │
│  K8s Secret: wallet-otel             ← synced from Vault               │
│                                                                          │
│  Pods mount these as env vars (no Vault SDK in app code)                │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## Setup (one-time)

### 1. Install Vault

```bash
# Option A: Helm (recommended for production)
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --set server.ha.enabled=true \
  --set server.ha.replicas=3

# Option B: Use the included manifest (dev/staging only)
kubectl apply -k deploy/k8s/base/vault
```

### 2. Initialize & unseal

```bash
kubectl -n vault exec -it vault-0 -- vault operator init -key-shares=5 -key-threshold=3
# Save the unseal keys + root token securely!

kubectl -n vault exec -it vault-0 -- vault operator unseal  # repeat 3x with different keys
```

### 3. Configure secrets

```bash
# Port-forward Vault
kubectl -n vault port-forward svc/vault 8200:8200 &
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=<root-token>

# Run the setup script
bash deploy/k8s/base/vault/setup-vault.sh
```

### 4. Install Vault Secrets Operator

```bash
helm install vault-secrets-operator hashicorp/vault-secrets-operator \
  --namespace vault
```

### 5. Apply the VaultStaticSecret CRDs

```bash
kubectl apply -f deploy/k8s/base/vault/vault-secrets-operator.yaml
```

The operator will create the K8s Secrets automatically — wallet-service pods
pick them up via `envFrom` / `env.valueFrom.secretKeyRef`.

## Secret Rotation

Vault supports two rotation models:

| Model | How | Wallet impact |
|-------|-----|---------------|
| **Manual** | `vault kv put secret/core-wallet/db/wallet-app password=NEW` | VSO syncs within `refreshAfter` (1h default); pods restart on Secret change (via annotation hash) |
| **Dynamic** | Vault database secrets engine (generates ephemeral credentials) | Short-lived creds, auto-rotate — requires Vault Enterprise or OSS with DB plugin |

For the wallet workload (PgBouncer connection pooling), manual rotation with a
rolling restart is sufficient. Dynamic secrets add complexity without major
security uplift since the credential lifetime is already bounded.

## Platform Differences

| Concern | AWS EKS | On-Premise |
|---------|---------|------------|
| Vault storage | DynamoDB / S3 (Raft in Helm chart) | Consul / Raft (Helm chart) |
| Auto-unseal | AWS KMS (`seal "awskms"`) | Shamir keys (manual) or Transit unseal |
| Audit backend | CloudWatch / S3 | File / syslog |
| HA | 3 pods + DynamoDB HA storage | 3 pods + Raft integrated storage |

## Files

| File | Purpose |
|------|---------|
| `vault-config.yaml` | Vault server deployment (single-node, file storage) |
| `vault-secrets-operator.yaml` | VaultStaticSecret CRDs (sync secrets → K8s) |
| `vault-policy.hcl` | Vault policy (read-only on wallet paths) |
| `setup-vault.sh` | One-time script: enable KV, write secrets, configure K8s auth |
