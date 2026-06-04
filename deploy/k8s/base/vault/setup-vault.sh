#!/usr/bin/env bash
# =============================================================================
# Vault initial setup for Core Wallet
# Run ONCE after Vault is initialized and unsealed.
#
# Prerequisites:
#   - Vault is running and unsealed
#   - VAULT_ADDR and VAULT_TOKEN are set
#   - kubectl has access to the cluster
# =============================================================================
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://vault.vault.svc.cluster.local:8200}"
echo "Using Vault at: $VAULT_ADDR"

# 1. Enable KV v2 secrets engine
vault secrets enable -path=secret kv-v2 2>/dev/null || echo "KV v2 already enabled"

# 2. Write wallet secrets
echo "Writing wallet DB secrets..."

vault kv put secret/core-wallet/db/wallet-app \
  username="wallet_app" \
  password="CHANGE_ME_wallet_app_prod" \
  host="pg-primary.wallet.svc.cluster.local" \
  port="5432" \
  dbname="wallet" \
  sslmode="require" \
  DB_DSN="postgres://wallet_app:CHANGE_ME_wallet_app_prod@localhost:6432/wallet?sslmode=disable"

vault kv put secret/core-wallet/db/wallet-pii-ro \
  username="wallet_pii_ro" \
  password="CHANGE_ME_wallet_pii_prod" \
  DB_PII_DSN="postgres://wallet_pii_ro:CHANGE_ME_wallet_pii_prod@localhost:6432/wallet?sslmode=disable"

vault kv put secret/core-wallet/db/wallet-eod \
  username="wallet_eod" \
  password="CHANGE_ME_wallet_eod_prod" \
  EOD_DSN="postgres://wallet_eod:CHANGE_ME_wallet_eod_prod@pg-primary.wallet.svc.cluster.local:5432/wallet?sslmode=require"

vault kv put secret/core-wallet/otel \
  OTEL_EXPORTER_OTLP_ENDPOINT="otel-collector.observability.svc.cluster.local:4317"

vault kv put secret/core-wallet/pii-dek \
  PII_DEK="CHANGE_ME_32_byte_encryption_key_here"

# 3. Write policy
echo "Writing vault policy..."
vault policy write wallet-service /vault/config/vault-policy.hcl

# 4. Enable Kubernetes auth
echo "Configuring Kubernetes auth..."
vault auth enable kubernetes 2>/dev/null || echo "Kubernetes auth already enabled"

# Get the K8s API info
K8S_HOST="https://kubernetes.default.svc.cluster.local:443"
K8S_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 --decode)
TOKEN_REVIEWER_JWT=$(kubectl get secret vault-auth-token -n vault -o jsonpath='{.data.token}' | base64 --decode 2>/dev/null || echo "")

vault write auth/kubernetes/config \
  kubernetes_host="$K8S_HOST" \
  kubernetes_ca_cert="$K8S_CA_CERT" \
  disable_local_ca_jwt=true

# 5. Create role for wallet-service
echo "Creating Kubernetes auth role..."
vault write auth/kubernetes/role/wallet-service \
  bound_service_account_names=wallet-service \
  bound_service_account_namespaces=wallet \
  policies=wallet-service \
  ttl=1h

echo ""
echo "✅ Vault setup complete!"
echo "   - Secrets: secret/core-wallet/db/*, secret/core-wallet/otel, secret/core-wallet/pii-dek"
echo "   - Policy: wallet-service"
echo "   - K8s auth role: wallet-service (bound to SA wallet-service in ns wallet)"
echo ""
echo "⚠️  CHANGE ALL PASSWORDS above before using in production!"
