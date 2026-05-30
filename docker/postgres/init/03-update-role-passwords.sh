#!/bin/sh
# Runs AFTER wallet_schema.sql.
# The schema script creates roles with placeholder password 'CHANGE_ME_IN_VAULT'
# inside its DO $$ ... IF NOT EXISTS block, but our 00-set-passwords.sh pre-created
# them with proper env passwords first, so the IF NOT EXISTS skips. This script is
# a safety net: forcibly re-applies the env-var passwords in case the schema ever
# changes to overwrite them.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  ALTER ROLE wallet_app     WITH PASSWORD '${WALLET_APP_PASSWORD}';
  ALTER ROLE wallet_pii_ro  WITH PASSWORD '${WALLET_PII_RO_PASSWORD}';
  ALTER ROLE wallet_admin   WITH PASSWORD '${WALLET_ADMIN_PASSWORD}';
EOSQL

echo "[init] role passwords re-aligned with env vars"
echo "[init] post-schema verification:"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  SELECT 'tables created' AS check, count(*) AS n
    FROM pg_tables WHERE schemaname='public' AND (tablename LIKE 'wlt_%' OR tablename LIKE 'fm_%');
  SELECT 'tran_def seed rows' AS check, count(*) AS n FROM WLT_TRAN_DEF;
  SELECT 'gl_mast seed rows' AS check, count(*) AS n FROM FM_GL_MAST;
  SELECT 'tran_hist partitions' AS check, count(*) AS n
    FROM pg_inherits WHERE inhparent = 'wlt_tran_hist'::regclass;
  SELECT 'audit triggers attached' AS check, count(*) AS n
    FROM pg_trigger WHERE tgname = 'trg_audit_cols' AND NOT tgisinternal;
  SELECT 'business SPs deployed' AS check, count(*) AS n
    FROM pg_proc
   WHERE proname IN ('post_topup','post_transfer','post_withdraw','post_withdraw_reversal',
                     'mark_withdraw_acked','mark_withdraw_disbursing','mark_withdraw_completed');
EOSQL
