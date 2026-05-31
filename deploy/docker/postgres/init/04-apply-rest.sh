#!/bin/sh
# Runs AFTER wallet_schema.sql (01) + wallet_sp.sql (02) + role passwords (03).
#
# docker auto-loads ONLY wallet_schema.sql + wallet_sp.sql. This script applies
# everything else a usable dev DB needs so a fresh `docker compose up` (new
# volume) yields a FULLY-migrated database with no manual psql steps:
#   - the remaining stored-function files (balance / merchant / reversals /
#     restraint / client / account / eod)
#   - reference seeds (chart of accounts, tran-type extensions) + demo data
#   - the tracked incremental migrations in db/migrations/
#
# The db/ tree is mounted read-only at /db (see docker-compose.yml). Order
# matters: SPs before the seeds/migrations that call them.
#
# NOTE: db/seeds/wallet_seed.sql is intentionally NOT applied — it is stale
# against the encrypted-PII schema (inserts WLT_CLIENT_KYC.PHONE_NO/EMAIL, which
# no longer exist). wallet_testdata_10.sql is the schema-correct demo seed. Swap
# it back in here once wallet_seed.sql is fixed.
set -e

DB="${POSTGRES_DB:-wallet}"

apply() {
  echo "[init] applying $1"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$DB" -f "$1"
}

# 1) Remaining stored functions (wallet_sp.sql already loaded as init step 02).
apply /db/procedures/wallet_sp_balance.sql
apply /db/procedures/wallet_sp_merchant.sql
apply /db/procedures/wallet_sp_topup_reversal.sql
apply /db/procedures/wallet_sp_transfer_reversal.sql
apply /db/procedures/wallet_sp_restraint.sql
apply /db/procedures/wallet_sp_client.sql
apply /db/procedures/wallet_sp_account.sql
apply /db/procedures/wallet_sp_eod.sql

# 2) Reference data + demo fixtures.
apply /db/seeds/wallet_coa_seed.sql
apply /db/seeds/wallet_tran_type_ext.sql
apply /db/seeds/wallet_testdata_10.sql

# 3) Incremental migrations that are NOT already folded into wallet_schema.sql.
#    A fresh install starts from the HEAD schema, so most of db/migrations/ is
#    redundant here and some files are stale against it (they target the
#    pre-rename WLT_BATCH or pre-evolution FM_CLIENT_BANKS and would error):
#      - rename_wlt_batch_to_wlt_gl_batch, drop_tranhist_columns,
#        evolve_fm_client_banks, get_client_masked_view, set_db_timezone
#        → already in wallet_schema.sql (no-op or conflict on a fresh DB)
#      - eod_period_locking_gl_feed → already created by wallet_sp_eod.sql above
#    Only ledger_integrity_hardening adds objects absent from a fresh DB
#    (wallet_eod role, balanced-posting trigger, DEFAULT partitions). It is
#    idempotent and resolves the GL-journal table name dynamically.
apply /db/migrations/2026-05-30_ledger_integrity_hardening.sql

echo "[init] procedures + seeds + migrations applied — DB fully migrated"
