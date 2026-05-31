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
    -- wallet_eod owns the tamper-evident EOD writes; schema.sql GRANTs to it.
    -- MUST exist before schema.sql or its grants abort init (ON_ERROR_STOP) and
    -- the seed never loads. NOLOGIN (EOD runs it on a direct connection).
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_eod') THEN
      CREATE ROLE wallet_eod NOLOGIN;
    END IF;
  END
  \$\$;
EOSQL

echo "[init] roles wallet_app / wallet_pii_ro / wallet_admin / wallet_eod ensured"
