#!/bin/sh
# Runs FIRST on initial container creation, before wallet_schema.sql.
# Pre-creates the wallet_* roles with passwords from env vars.
# The schema script's DO $$ ... IF NOT EXISTS ... blocks will then skip role creation.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  DO \$\$
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_app') THEN
      CREATE ROLE wallet_app LOGIN PASSWORD '${WALLET_APP_PASSWORD}';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_pii_ro') THEN
      CREATE ROLE wallet_pii_ro LOGIN PASSWORD '${WALLET_PII_RO_PASSWORD}';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_admin') THEN
      CREATE ROLE wallet_admin LOGIN PASSWORD '${WALLET_ADMIN_PASSWORD}' CREATEDB CREATEROLE;
    END IF;
  END
  \$\$;
EOSQL

echo "[init] roles wallet_app / wallet_pii_ro / wallet_admin ensured"
