# Wallet DB Migration Export

Plain-SQL export of the `wallet` database (PostgreSQL 17.10), prepared for migrating
to a fresh target cluster. **Full schema for all 251 tables/partitions + 36 user
functions + 2 extensions**, with **business/master data included** but **loadtest
bulk data and operational/runtime artifacts excluded**.

Generated: 2026-05-31 · Source: local dev `wallet` DB (latest schema — WLT_GL_BATCH
rename, GL accounting cutoff, trimmed WLT_TRAN_HIST, EOD period-locking).

## Files (restore in order)

| # | File | Contents |
|---|------|----------|
| 1 | `01_roles.sql` | App roles `wallet_admin`, `wallet_app`, `wallet_pii_ro` (passwords NOT included — set them on target). `postgres` bootstrap included; drop/edit on the target as needed. |
| 2 | `02_wallet_schema_data.sql` | Full schema (tables, partitions, indexes, constraints, functions, `CREATE EXTENSION pgcrypto`/`uuid-ossp`) + master/business data. |

## What's in the data

**Included (master / business data):** `wlt_tran_def` (36 tran types), `fm_gl_mast`
(62 GL accounts), `wlt_gl_map` (23), `fm_currency`, `wlt_acct_type`, `wlt_acct` +
`wlt_acct_bal` (20 system/COA accounts + balances), `fm_client`/`wlt_client_kyc` and
the `fm_client_*` child tables, and all small config tables — **209 data rows total**.

**Schema only, data excluded (loadtest bulk):** `wlt_gl_batch`, `wlt_api_message`,
`wlt_withdraw_track`, `wlt_outbox*`, `wlt_client_audit_log*`, `wlt_tran_hist*`.

**Schema only, data excluded (operational / runtime artifacts):** `wlt_eod_run`,
`wlt_eod_audit_log`, `wlt_trial_balance`, `wlt_trial_balance_proof`, `wlt_restraints`
— these are produced by running the system (EOD close, trial-balance hash chain,
balance holds), not master data, so a fresh cluster must start them empty (importing
a dev cluster's tamper-evident hash chain as genesis would be incorrect).

All excluded tables exist (empty) on the target.

## Restore on target

Target must be an **empty** database (this export has no `DROP`/`--clean`).

```bash
# 1. Roles (run once per cluster, as a superuser)
psql -h <host> -p <port> -U postgres -f 01_roles.sql

# 2. Set real passwords for the app roles (--no-role-passwords omits them from 01)
psql -h <host> -p <port> -U postgres \
  -c "ALTER ROLE wallet_app    WITH PASSWORD '...';" \
  -c "ALTER ROLE wallet_admin  WITH PASSWORD '...';" \
  -c "ALTER ROLE wallet_pii_ro WITH PASSWORD '...';"

# 3. Create the target DB and load schema + data
psql -h <host> -p <port> -U postgres -c "CREATE DATABASE wallet;"
psql -h <host> -p <port> -U postgres -d wallet -v ON_ERROR_STOP=1 -f 02_wallet_schema_data.sql
```

## Verification

This export was smoke-tested by restoring `02` into a throwaway DB with
`ON_ERROR_STOP=1` — completed with **no errors**. Restored object counts: 251
tables/partitions, 91 routines (36 user + extension-owned); loadtest and
operational tables present but empty; master data = 209 rows.

## Regenerate

```bash
docker compose exec -T postgres pg_dumpall -U postgres --roles-only --no-role-passwords > db/migration/01_roles.sql
docker compose exec -T postgres pg_dump -U postgres -d wallet --format=plain \
  --exclude-table-data='public.wlt_gl_batch' \
  --exclude-table-data='public.wlt_api_message' \
  --exclude-table-data='public.wlt_withdraw_track' \
  --exclude-table-data='public.wlt_outbox*' \
  --exclude-table-data='public.wlt_client_audit_log*' \
  --exclude-table-data='public.wlt_tran_hist*' \
  --exclude-table-data='public.wlt_eod_run' \
  --exclude-table-data='public.wlt_eod_audit_log' \
  --exclude-table-data='public.wlt_trial_balance' \
  --exclude-table-data='public.wlt_trial_balance_proof' \
  --exclude-table-data='public.wlt_restraints' \
  > db/migration/02_wallet_schema_data.sql
```
