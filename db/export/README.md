# DB export — consolidated schema + seed

The wallet database is defined by **two generated files**, restored in order:

| # | File | Contents |
|---|------|----------|
| 1 | `schema.sql` | All DDL — tables (incl. the 4 partitioned **parents**, no child partitions), sequences, indexes, constraints, functions, procedures, triggers (incl. the balanced-posting `CONSTRAINT TRIGGER`), views, `pgcrypto`/`uuid-ossp` extensions, and GRANTs. **No data, no partitions.** |
| 2 | `partitions.sql` | Monthly partitions for the 4 parents (`wlt_tran_hist` also HASH-subpartitioned, modulus 32) + a DEFAULT partition per parent. `fn_ensure_wallet_partitions(from, to)` is idempotent and re-runnable to roll partitions forward. |
| 3 | `seed.sql` | Reference / master data only (data-only): `fm_gl_mast` (GL master), `wlt_gl_map` (COA map), `wlt_tran_def` (tran types), `fm_currency`, `wlt_acct_type`. |

`schema.sql` GRANTs to roles `wallet_app`, `wallet_pii_ro`, `wallet_eod`, so those
roles must exist before restore. The docker stack creates them in
`deploy/docker/postgres/init/00-set-passwords.sh`; on another target create them
first (passwords are not in these files).

These files replace the former per-object sources (`db/ddl/wallet_schema.sql`,
`db/procedures/*.sql`, `db/seeds/wallet_coa_seed.sql`,
`db/seeds/wallet_tran_type_ext.sql`) and the incremental `db/migrations/*.sql`,
all of which are now folded into `schema.sql` / `seed.sql`.

## Restore on an empty database

```bash
psql -U postgres -d wallet -v ON_ERROR_STOP=1 -f schema.sql
psql -U postgres -d wallet -v ON_ERROR_STOP=1 -f seed.sql
```

The docker stack does this automatically on first volume init (mounted as
`01-schema.sql` / `02-seed.sql` — see `docker-compose.yml`).

## Regenerate (from a fully-migrated source DB)

```bash
# 1. schema (DDL + grants, no ownership)
docker compose exec -T postgres pg_dump -U postgres -d wallet \
  --schema-only --no-owner > db/export/schema.sql

# 2. reference seed (data-only; --disable-triggers handles the self-referential
#    fm_gl_mast FK on restore)
docker compose exec -T postgres pg_dump -U postgres -d wallet \
  --data-only --no-owner --disable-triggers \
  -t fm_gl_mast -t wlt_gl_map -t wlt_tran_def -t fm_currency -t wlt_acct_type \
  > db/export/seed.sql
```

Prepend the header comment block to each after regenerating.
