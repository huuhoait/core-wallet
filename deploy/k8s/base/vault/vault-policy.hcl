# =============================================================================
# Vault Policy for wallet-service
# Apply with: vault policy write wallet-service vault-policy.hcl
# =============================================================================

# Read DB credentials (all roles)
path "secret/data/core-wallet/db/*" {
  capabilities = ["read"]
}

# Read OTel configuration
path "secret/data/core-wallet/otel" {
  capabilities = ["read"]
}

# Read PII encryption key (DEK)
path "secret/data/core-wallet/pii-dek" {
  capabilities = ["read"]
}

# Deny everything else by default (Vault's implicit deny)
