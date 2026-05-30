-- =============================================================================
-- 2026-05-30_evolve_fm_client_banks.sql — Incremental schema change
-- (tracked incremental migrations live in db/migrations/; db/migration/ is the
--  gitignored full-dump export — see db/migration/README.md)
-- =============================================================================
-- Purpose:  Evolve FM_CLIENT_BANKS from the composite-key contact-row design to a
--           surrogate-keyed "linked bank account" design.
--
-- Changes (vs deployed schema captured in 02_wallet_schema_data.sql):
--   - DROP composite PK (CLIENT_NO, SEQ_NO)        → DROP COLUMN SEQ_NO
--   - ADD  LINK_ID BIGINT IDENTITY                 → new surrogate PRIMARY KEY
--   - RENAME ACCT_NAME → ACCT_HOLDER_NAME          (semantics unchanged)
--   - ADD  BANK_NAME       VARCHAR(120)            (bank display name, split out)
--   - ADD  IS_DEFAULT      SMALLINT NOT NULL DEF 0 (customer's default payout bank)
--   - ADD  CHECK is_default IN (0,1)
--   - ADD  partial UNIQUE  (at most one default bank per client)
--
-- Preserved automatically by ALTER (no action needed):
--   FK fk_cb_client, GRANT to wallet_pii_ro, trigger trg_audit_cols,
--   audit columns CHANNEL/CREATED_AT/CREATED_BY/UPDATED_AT/UPDATED_BY.
--
-- Data safety: deployed FM_CLIENT_BANKS is empty (0 rows). Operations are also
-- data-safe if rows exist: IDENTITY backfills existing rows; IS_DEFAULT defaults
-- to 0 so the partial-unique index cannot conflict. No SP/Go/seed writes this
-- table today (only docs + maintenance/teardown reference it by name).
--
-- Apply order:  after 02_wallet_schema_data.sql (or to any DB already on the
--               deployed schema). Re-run pg_dump afterwards to refresh 02.
-- Target:       PostgreSQL 17+
-- Idempotent:   guarded with IF EXISTS / IF NOT EXISTS where possible.
-- Version:      2026-05-30
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

-- 1. Surrogate primary key ----------------------------------------------------
ALTER TABLE fm_client_banks DROP CONSTRAINT IF EXISTS fm_client_banks_pkey;

ALTER TABLE fm_client_banks DROP COLUMN IF EXISTS seq_no;

ALTER TABLE fm_client_banks
  ADD COLUMN IF NOT EXISTS link_id BIGINT GENERATED ALWAYS AS IDENTITY;

ALTER TABLE fm_client_banks
  ADD CONSTRAINT fm_client_banks_pkey PRIMARY KEY (link_id);

-- 2. Business columns ---------------------------------------------------------
-- acct_name held the account-holder name in the old design.
ALTER TABLE fm_client_banks RENAME COLUMN acct_name TO acct_holder_name;

ALTER TABLE fm_client_banks
  ADD COLUMN IF NOT EXISTS bank_name  VARCHAR(120);

ALTER TABLE fm_client_banks
  ADD COLUMN IF NOT EXISTS is_default SMALLINT NOT NULL DEFAULT 0;

-- 3. Integrity ----------------------------------------------------------------
ALTER TABLE fm_client_banks
  ADD CONSTRAINT chk_cb_default CHECK (is_default IN (0, 1));

CREATE INDEX IF NOT EXISTS idx_cb_client ON fm_client_banks (client_no);

-- At most one default bank per client.
CREATE UNIQUE INDEX IF NOT EXISTS uk_cb_one_default
  ON fm_client_banks (client_no) WHERE is_default = 1;

COMMIT;

-- Verify:
--   \d fm_client_banks
--   SELECT column_name, ordinal_position, data_type
--     FROM information_schema.columns
--    WHERE table_name = 'fm_client_banks' ORDER BY ordinal_position;
