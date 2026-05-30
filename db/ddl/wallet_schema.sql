-- =============================================================================
-- Core Wallet Schema — Y1 (20 TPS scope)
--
-- Single-file deployable script. Order matters: roles → extensions → schemas →
-- FM tier → WLT master → WLT transactional → WLT control → audit → triggers →
-- views → seed → permissions → per-table tunings.
--
-- Target:        PostgreSQL 17+
-- Companion:     wallet_HLD_20tps.md (architecture), wallet_DLD.md (detail),
--                wallet_seed.sql (helper functions + bulk test-data generator)
-- Version:       1.0   (2026-05-28)
--
-- Usage:
--   createdb wallet
--   psql -d wallet -f wallet_schema.sql
--
-- If integrating with an existing T24/FM core, SKIP §3 (FM tier) and instead
-- create FK targets via cross-schema GRANT REFERENCES.
-- =============================================================================

\set ON_ERROR_STOP on
\timing on

BEGIN;

-- =============================================================================
-- §1. ROLES
-- =============================================================================

-- Application service role — used by Go service via PgBouncer.
-- Has DML on WLT but NO direct INSERT into WLT_OUTBOX (writes go through SPs).
-- Reads FM via masked views only — no direct P1 column access.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_app') THEN
    CREATE ROLE wallet_app LOGIN PASSWORD 'CHANGE_ME_IN_VAULT';
  END IF;
END $$;

-- Compliance/audit read role — can read P1 columns with full audit logging.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_pii_ro') THEN
    CREATE ROLE wallet_pii_ro LOGIN PASSWORD 'CHANGE_ME_IN_VAULT';
  END IF;
END $$;

-- Break-glass admin — schema changes + key rotation. JIT-granted, MFA-required.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_admin') THEN
    CREATE ROLE wallet_admin LOGIN PASSWORD 'CHANGE_ME_IN_VAULT' CREATEDB CREATEROLE;
  END IF;
END $$;


-- =============================================================================
-- §2. EXTENSIONS
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;             -- pgp_sym_encrypt for PII at rest
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";          -- gen_random_uuid in event UUIDs
-- pg_partman + pg_cron deferred to Y2 (manual partitions are enough at 20 TPS)

-- Pin the business timezone (GMT+7, no DST) at DB level so CURRENT_DATE / now()
-- and all accounting dates are independent of the host/container OS tz and
-- consistent across PgBouncer-pooled backends. Applies to NEW sessions.
DO $$ BEGIN
  EXECUTE format('ALTER DATABASE %I SET timezone = %L', current_database(), 'Asia/Ho_Chi_Minh');
END $$;


-- =============================================================================
-- §3. FM TIER  (skip this section if integrating with an existing T24/FM core)
-- =============================================================================

-- ─── FM_CURRENCY ──────────────────────────────────────────────────────────
CREATE TABLE FM_CURRENCY (
  CCY              VARCHAR(4)    PRIMARY KEY,
  CCY_DESC         VARCHAR(80)   NOT NULL,
  DECI_PLACES      SMALLINT      NOT NULL DEFAULT 2,
  DAY_BASIS        SMALLINT      NOT NULL DEFAULT 360,
  ROUND_TRUNC      VARCHAR(4),
  CCY_GROUP        VARCHAR(4),
  STATUS           VARCHAR(4)    NOT NULL DEFAULT 'A'
);

-- ─── FM_GL_MAST ───────────────────────────────────────────────────────────
CREATE TABLE FM_GL_MAST (
  GL_CODE          VARCHAR(32)   PRIMARY KEY,
  GL_CODE_DESC     VARCHAR(120)  NOT NULL,
  GL_CODE_TYPE     VARCHAR(4),                 -- 'A','L','I','E'
  CONTROL_GL_CODE  VARCHAR(32),                -- parent in account tree
  BSPL_TYPE        VARCHAR(4),                 -- 'B','P'
  GL_TYPE          VARCHAR(12),                -- 'CASH','LIAB','NOSTRO','REV','TAX',...
  TFR_IND          VARCHAR(4),
  STATUS           VARCHAR(4)    NOT NULL DEFAULT 'A',
  CONSTRAINT fk_gl_parent FOREIGN KEY (CONTROL_GL_CODE) REFERENCES FM_GL_MAST(GL_CODE)
);
CREATE INDEX idx_fm_gl_type ON FM_GL_MAST(GL_CODE_TYPE, BSPL_TYPE);

-- ─── FM_CLIENT ────────────────────────────────────────────────────────────
CREATE TABLE FM_CLIENT (
  CLIENT_NO            VARCHAR(48)   PRIMARY KEY,
  GLOBAL_ID            VARCHAR(64),
  GLOBAL_ID_TYPE       VARCHAR(12),
  CLIENT_NAME          VARCHAR(200)  NOT NULL,
  CLIENT_SHORT         VARCHAR(100),
  CLIENT_TYPE          VARCHAR(12),            -- 'IND','CORP'
  CLIENT_GRP           VARCHAR(48),
  ACCT_EXEC            VARCHAR(12),
  COUNTRY_LOC          VARCHAR(8),
  COUNTRY_CITIZEN      VARCHAR(8),
  COUNTRY_RISK         VARCHAR(8),
  STATE_LOC            VARCHAR(8),
  REGISTERED_DATE      DATE,
  NON_RESIDENT_CTRL    VARCHAR(4),
  TAX_FILE_NO          VARCHAR(60),
  TAXABLE_IND          VARCHAR(4),
  STATUS               VARCHAR(4)    NOT NULL DEFAULT 'A',
  CREATED_AT           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UPDATED_AT           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  CONSTRAINT uk_fm_client_gid UNIQUE (GLOBAL_ID, GLOBAL_ID_TYPE)
);
CREATE INDEX idx_fm_client_name   ON FM_CLIENT(CLIENT_NAME);
CREATE INDEX idx_fm_client_status ON FM_CLIENT(STATUS) WHERE STATUS = 'A';

-- ─── FM_CLIENT_INDVL ──────────────────────────────────────────────────────
CREATE TABLE FM_CLIENT_INDVL (
  CLIENT_NO        VARCHAR(48)   PRIMARY KEY,
  SURNAME          VARCHAR(80),
  GIVEN_NAME_1     VARCHAR(80),
  BIRTH_DATE       DATE,
  SEX              VARCHAR(4),
  RESIDENT_STATUS  VARCHAR(4),
  MARITAL_STATUS   VARCHAR(4),
  OCCUPATION_CODE  VARCHAR(24),
  CONSTRAINT fk_indvl_client FOREIGN KEY (CLIENT_NO) REFERENCES FM_CLIENT(CLIENT_NO)
);

-- ─── FM_CLIENT_IDENTIFIERS ────────────────────────────────────────────────
CREATE TABLE FM_CLIENT_IDENTIFIERS (
  CLIENT_NO         VARCHAR(48)   NOT NULL,
  GLOBAL_ID         VARCHAR(64)   NOT NULL,    -- encrypted P1 in app layer
  GLOBAL_ID_TYPE    VARCHAR(20)   NOT NULL,
  DT_OF_ISSUANCE    DATE,
  EXPIRY_DATE       DATE,
  PLACE_OF_ISSUANCE VARCHAR(120),
  IS_CURRENT        SMALLINT      NOT NULL DEFAULT 1,
  NATIONALITY       VARCHAR(8),
  PRIMARY KEY (CLIENT_NO, GLOBAL_ID, GLOBAL_ID_TYPE),
  CONSTRAINT fk_idf_client FOREIGN KEY (CLIENT_NO) REFERENCES FM_CLIENT(CLIENT_NO)
);

-- ─── FM_CLIENT_CONTACT ────────────────────────────────────────────────────
CREATE TABLE FM_CLIENT_CONTACT (
  CLIENT_NO        VARCHAR(48)   NOT NULL,
  CONTACT_TYPE     VARCHAR(12)   NOT NULL,    -- 'PRI','BIL','RES'
  ADDR_LINE1       VARCHAR(200),
  ADDR_LINE2       VARCHAR(200),
  CITY             VARCHAR(80),
  COUNTRY          VARCHAR(8),
  PHONE_NO_ENC     BYTEA,                      -- encrypted P1
  EMAIL_ENC        BYTEA,                      -- encrypted P1
  PRIMARY KEY (CLIENT_NO, CONTACT_TYPE),
  CONSTRAINT fk_ct_client FOREIGN KEY (CLIENT_NO) REFERENCES FM_CLIENT(CLIENT_NO)
);

-- ─── FM_CLIENT_BANKS (linked bank accounts) ───────────────────────────────
-- Audit columns CHANNEL/CREATED_AT/CREATED_BY/UPDATED_AT/UPDATED_BY are appended
-- by the §8 audit DO-loop (kept off the CREATE list, like every other table).
CREATE TABLE FM_CLIENT_BANKS (
  LINK_ID          BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  CLIENT_NO        VARCHAR(48)   NOT NULL,
  BANK_CODE        VARCHAR(20)   NOT NULL,    -- NAPAS BIN / bank swift
  BANK_NAME        VARCHAR(120),
  ACCT_NO_ENC      BYTEA         NOT NULL,    -- encrypted P1
  ACCT_HOLDER_NAME VARCHAR(200),
  IS_DEFAULT       SMALLINT      NOT NULL DEFAULT 0,
  STATUS           VARCHAR(4)    NOT NULL DEFAULT 'A',
  VERIFIED_AT      TIMESTAMPTZ,
  CONSTRAINT fk_cb_client  FOREIGN KEY (CLIENT_NO) REFERENCES FM_CLIENT(CLIENT_NO),
  CONSTRAINT chk_cb_default CHECK (IS_DEFAULT IN (0, 1))
);
CREATE INDEX idx_cb_client ON FM_CLIENT_BANKS(CLIENT_NO);
-- At most one default bank per client.
CREATE UNIQUE INDEX uk_cb_one_default ON FM_CLIENT_BANKS(CLIENT_NO) WHERE IS_DEFAULT = 1;

-- ─── FM_NOS_VOS ───────────────────────────────────────────────────────────
CREATE TABLE FM_NOS_VOS (
  NOS_VOS_NO       BIGINT        PRIMARY KEY,
  ACCT_TYPE        VARCHAR(12)   NOT NULL,    -- 'NOSTRO','VOSTRO','TKDBTT'
  CCY              VARCHAR(4)    NOT NULL,
  CLIENT_NO        VARCHAR(48),
  ACCT_DESC        VARCHAR(120),
  GL_CODE          VARCHAR(32)   NOT NULL,
  ACCT_NO          VARCHAR(80)   NOT NULL,
  INTERNAL_KEY     BIGINT,
  STATUS           VARCHAR(4)    NOT NULL DEFAULT 'A',
  CONSTRAINT fk_nos_gl  FOREIGN KEY (GL_CODE) REFERENCES FM_GL_MAST(GL_CODE),
  CONSTRAINT fk_nos_ccy FOREIGN KEY (CCY)     REFERENCES FM_CURRENCY(CCY)
);


-- =============================================================================
-- §4. WLT TIER — MASTER / REFERENCE
-- =============================================================================

-- ─── WLT_CLIENT_KYC ───────────────────────────────────────────────────────
CREATE TABLE WLT_CLIENT_KYC (
  KYC_ID            BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  CLIENT_NO         VARCHAR(48)   NOT NULL,
  PHONE_NO_ENC      BYTEA         NOT NULL,            -- encrypted P1 (was PHONE_NO)
  PHONE_NO_HASH     BYTEA         NOT NULL,            -- HMAC-SHA256 for unique index
  EMAIL_ENC         BYTEA,
  KYC_TIER          VARCHAR(4)    NOT NULL DEFAULT '1',
  EKYC_PROVIDER     VARCHAR(40),
  EKYC_REF          VARCHAR(80),
  FACE_MATCH_SCORE  NUMERIC(5,3),
  LIVENESS_RESULT   VARCHAR(8),
  DOC_URL           VARCHAR(400),
  STATUS            VARCHAR(4)    NOT NULL DEFAULT 'A',
  RISK_LEVEL        VARCHAR(4)    NOT NULL DEFAULT 'L',
  VERIFIED_AT       TIMESTAMPTZ,
  VERIFIED_BY       VARCHAR(40),
  CREATED_AT        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UPDATED_AT        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_kyc_client FOREIGN KEY (CLIENT_NO) REFERENCES FM_CLIENT(CLIENT_NO),
  CONSTRAINT chk_kyc_tier  CHECK (KYC_TIER IN ('0','1','2','3')),
  CONSTRAINT chk_kyc_st    CHECK (STATUS IN ('A','B','C','P'))
);
CREATE UNIQUE INDEX uk_kyc_phone_hash ON WLT_CLIENT_KYC(PHONE_NO_HASH);
CREATE INDEX idx_kyc_client          ON WLT_CLIENT_KYC(CLIENT_NO);
CREATE INDEX idx_kyc_tier            ON WLT_CLIENT_KYC(KYC_TIER) WHERE STATUS = 'A';

-- ─── WLT_ACCT_TYPE ────────────────────────────────────────────────────────
CREATE TABLE WLT_ACCT_TYPE (
  ACCT_TYPE        VARCHAR(12)   PRIMARY KEY,
  ACCT_TYPE_DESC   VARCHAR(80)   NOT NULL,
  GL_CODE_LIAB     VARCHAR(32)   NOT NULL,
  PROD_ID          VARCHAR(16),
  DAILY_LIMIT      NUMERIC(18,2) NOT NULL DEFAULT 20000000,
  MONTHLY_LIMIT    NUMERIC(18,2) NOT NULL DEFAULT 100000000,
  INT_BEARING      VARCHAR(1)    NOT NULL DEFAULT 'N',
  STATUS           VARCHAR(4)    NOT NULL DEFAULT 'A',
  CONSTRAINT fk_at_gl FOREIGN KEY (GL_CODE_LIAB) REFERENCES FM_GL_MAST(GL_CODE)
);

-- ─── WLT_ACCT_GROUP (sub-account sharding container — created Y1, used later) ──
CREATE TABLE WLT_ACCT_GROUP (
  GROUP_ID             VARCHAR(20)   PRIMARY KEY,
  CLIENT_NO            VARCHAR(48)   NOT NULL,
  GROUP_TYPE           VARCHAR(12)   NOT NULL,
  SHARD_COUNT          SMALLINT      NOT NULL DEFAULT 32,
  SETTLEMENT_ACCT_NO   VARCHAR(20)   NOT NULL,
  SHARD_THRESHOLD      NUMERIC(18,2) NOT NULL DEFAULT 200000,
  SHARD_BUFFER         NUMERIC(18,2) NOT NULL DEFAULT 50000,
  SWEEP_INTERVAL_SEC   SMALLINT      NOT NULL DEFAULT 60,
  GROUP_STATUS         VARCHAR(4)    NOT NULL DEFAULT 'A',
  CREATED_AT           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UPDATED_AT           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_group_client FOREIGN KEY (CLIENT_NO) REFERENCES FM_CLIENT(CLIENT_NO),
  CONSTRAINT chk_group_type  CHECK (GROUP_TYPE IN ('MERCHANT','AGENT','NOSTRO_HOT')),
  CONSTRAINT chk_shard_count CHECK (SHARD_COUNT IN (8, 16, 32, 64))
);
CREATE INDEX idx_group_client ON WLT_ACCT_GROUP(CLIENT_NO);
CREATE INDEX idx_group_status ON WLT_ACCT_GROUP(GROUP_STATUS) WHERE GROUP_STATUS = 'A';

-- ─── WLT_ACCT ─────────────────────────────────────────────────────────────
CREATE TABLE WLT_ACCT (
  INTERNAL_KEY         BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ACCT_NO              VARCHAR(20)   NOT NULL UNIQUE,
  CLIENT_NO            VARCHAR(48)   NOT NULL,
  ACCT_TYPE            VARCHAR(12)   NOT NULL,
  CCY                  VARCHAR(4)    NOT NULL DEFAULT 'VND',
  ACCT_STATUS          VARCHAR(4)    NOT NULL DEFAULT 'A',
  ACTUAL_BAL           NUMERIC(18,2) NOT NULL DEFAULT 0,
  TOTAL_RESTRAINED_AMT NUMERIC(18,2) NOT NULL DEFAULT 0,
  CALC_BAL             NUMERIC(18,2) GENERATED ALWAYS AS (ACTUAL_BAL - TOTAL_RESTRAINED_AMT) STORED,
  PREV_DAY_ACTUAL_BAL  NUMERIC(18,2) NOT NULL DEFAULT 0,
  ACCT_OPEN_DATE       DATE          NOT NULL DEFAULT CURRENT_DATE,
  LAST_TRAN_DATE       TIMESTAMPTZ,
  RESTRAINT_PRESENT    VARCHAR(4)    NOT NULL DEFAULT 'N',
  CR_BLOCKED           VARCHAR(1)    NOT NULL DEFAULT 'N',
  VERSION              INTEGER       NOT NULL DEFAULT 0,
  -- Sharding columns (default STANDALONE — sharding deferred Y1)
  GROUP_ID             VARCHAR(20),
  SHARD_INDEX          SMALLINT,
  ACCT_ROLE            VARCHAR(12)   NOT NULL DEFAULT 'STANDALONE',
  -- FKs
  CONSTRAINT fk_acct_fm_client  FOREIGN KEY (CLIENT_NO) REFERENCES FM_CLIENT(CLIENT_NO),
  CONSTRAINT fk_acct_fm_ccy     FOREIGN KEY (CCY)       REFERENCES FM_CURRENCY(CCY),
  CONSTRAINT fk_acct_type       FOREIGN KEY (ACCT_TYPE) REFERENCES WLT_ACCT_TYPE(ACCT_TYPE),
  CONSTRAINT fk_acct_group      FOREIGN KEY (GROUP_ID)  REFERENCES WLT_ACCT_GROUP(GROUP_ID),
  -- Invariants
  CONSTRAINT chk_acct_status    CHECK (ACCT_STATUS IN ('A','B','C','P','F')),
  CONSTRAINT chk_acct_bal       CHECK (ACTUAL_BAL >= 0),
  CONSTRAINT chk_acct_avail     CHECK (ACTUAL_BAL >= TOTAL_RESTRAINED_AMT),
  CONSTRAINT chk_acct_restrained CHECK (TOTAL_RESTRAINED_AMT >= 0),
  CONSTRAINT chk_acct_role      CHECK (ACCT_ROLE IN ('STANDALONE','SHARD','SETTLEMENT')),
  CONSTRAINT chk_shard_consistency CHECK (
    (ACCT_ROLE = 'STANDALONE' AND GROUP_ID IS NULL     AND SHARD_INDEX IS NULL) OR
    (ACCT_ROLE = 'SHARD'      AND GROUP_ID IS NOT NULL AND SHARD_INDEX IS NOT NULL) OR
    (ACCT_ROLE = 'SETTLEMENT' AND GROUP_ID IS NOT NULL AND SHARD_INDEX IS NULL)
  )
);
CREATE INDEX idx_acct_client       ON WLT_ACCT(CLIENT_NO);
CREATE INDEX idx_acct_status_type  ON WLT_ACCT(ACCT_STATUS, ACCT_TYPE);
CREATE INDEX idx_acct_ccy          ON WLT_ACCT(CCY);
CREATE INDEX idx_acct_group_role   ON WLT_ACCT(GROUP_ID, ACCT_ROLE) WHERE GROUP_ID IS NOT NULL;
CREATE UNIQUE INDEX uk_acct_shard       ON WLT_ACCT(GROUP_ID, SHARD_INDEX) WHERE ACCT_ROLE = 'SHARD';
CREATE UNIQUE INDEX uk_acct_settlement  ON WLT_ACCT(GROUP_ID) WHERE ACCT_ROLE = 'SETTLEMENT';

-- Add the deferred settlement FK on WLT_ACCT_GROUP now that WLT_ACCT exists.
ALTER TABLE WLT_ACCT_GROUP
  ADD CONSTRAINT fk_group_settlement
  FOREIGN KEY (SETTLEMENT_ACCT_NO) REFERENCES WLT_ACCT(ACCT_NO)
  DEFERRABLE INITIALLY DEFERRED;

-- ─── WLT_TRAN_DEF ─────────────────────────────────────────────────────────
CREATE TABLE WLT_TRAN_DEF (
  TRAN_TYPE             VARCHAR(10)   PRIMARY KEY,     -- e.g. 'TRFOUT','WDRAW','MERCHWD','PAYMENT'
  TRAN_DESC             VARCHAR(120),
  CR_DR_MAINT_IND       VARCHAR(4)    NOT NULL,        -- 'DR','CR','BOTH'
  REVERSAL_TRAN_TYPE    VARCHAR(10),
  CHECK_FUND_IND        VARCHAR(1)    NOT NULL DEFAULT 'Y',
  CHECK_RESTRAINT_IND   VARCHAR(1)    NOT NULL DEFAULT 'Y',
  SOURCE_TYPE           VARCHAR(8),
  CONTRA_GL_CODE        VARCHAR(32),
  MIN_TRAN_AMT          NUMERIC(18,2) NOT NULL DEFAULT 1000,
  MAX_TRAN_AMT          NUMERIC(18,2) NOT NULL DEFAULT 100000000,
  MAX_FUTURE_DATE_DAYS  SMALLINT      NOT NULL DEFAULT 0,
  AUTO_APPROVAL         VARCHAR(1)    NOT NULL DEFAULT 'Y',
  NARRATIVE             VARCHAR(160),
  STATUS                VARCHAR(1)    NOT NULL DEFAULT 'A',
  -- Fee + VAT
  FEE_TYPE              VARCHAR(8)    NOT NULL DEFAULT 'NONE',
  FEE_AMT               NUMERIC(18,2) NOT NULL DEFAULT 0,
  FEE_RATE              NUMERIC(10,6) NOT NULL DEFAULT 0,
  FEE_MIN               NUMERIC(18,2) NOT NULL DEFAULT 0,
  FEE_MAX               NUMERIC(18,2) NOT NULL DEFAULT 0,
  VAT_RATE              NUMERIC(6,4)  NOT NULL DEFAULT 0.10,
  FEE_GL_CODE           VARCHAR(32),
  VAT_GL_CODE           VARCHAR(32),
  FEE_TRAN_TYPE         VARCHAR(10),
  CONSTRAINT chk_def_fee_type CHECK (FEE_TYPE IN ('NONE','FIXED','PERCENT')),
  CONSTRAINT chk_def_cr_dr    CHECK (CR_DR_MAINT_IND IN ('DR','CR','BOTH')),
  CONSTRAINT fk_def_fee_gl    FOREIGN KEY (FEE_GL_CODE) REFERENCES FM_GL_MAST(GL_CODE),
  CONSTRAINT fk_def_vat_gl    FOREIGN KEY (VAT_GL_CODE) REFERENCES FM_GL_MAST(GL_CODE)
);

-- ─── WLT_GL_MAP ───────────────────────────────────────────────────────────
CREATE TABLE WLT_GL_MAP (
  ACCT_TYPE     VARCHAR(12)  NOT NULL,
  EVENT_TYPE    VARCHAR(16)  NOT NULL,
  GL_CODE       VARCHAR(32)  NOT NULL,
  GL_DESC       VARCHAR(120),
  PRIMARY KEY (ACCT_TYPE, EVENT_TYPE),
  CONSTRAINT fk_glmap_gl   FOREIGN KEY (GL_CODE)   REFERENCES FM_GL_MAST(GL_CODE),
  CONSTRAINT fk_glmap_type FOREIGN KEY (ACCT_TYPE) REFERENCES WLT_ACCT_TYPE(ACCT_TYPE)
);

-- ─── WLT_NOSTRO_LINK ──────────────────────────────────────────────────────
CREATE TABLE WLT_NOSTRO_LINK (
  NOSTRO_ID        VARCHAR(16)   PRIMARY KEY,
  NOS_VOS_NO       BIGINT        NOT NULL UNIQUE,
  GL_CODE          VARCHAR(32)   NOT NULL,
  PURPOSE          VARCHAR(16)   NOT NULL DEFAULT 'TKDBTT',
  REG_NHNN_CODE    VARCHAR(32),
  STATUS           VARCHAR(4)    NOT NULL DEFAULT 'A',
  LAST_RECON_DATE  DATE,
  LAST_RECON_BAL   NUMERIC(18,2),
  CONSTRAINT fk_nl_fm  FOREIGN KEY (NOS_VOS_NO) REFERENCES FM_NOS_VOS(NOS_VOS_NO),
  CONSTRAINT fk_nl_gl  FOREIGN KEY (GL_CODE)    REFERENCES FM_GL_MAST(GL_CODE)
);


-- =============================================================================
-- §5. WLT TIER — TRANSACTIONAL  (partitioned)
-- =============================================================================

-- ─── Sequence for TFR_INTERNAL_KEY (shared across legs of a single transfer) ─
CREATE SEQUENCE seq_tfr AS BIGINT CACHE 1000;

-- ─── WLT_TRAN_HIST (range by month → hash by INTERNAL_KEY × 32) ────────────
CREATE TABLE WLT_TRAN_HIST (
  INTERNAL_KEY        BIGINT        NOT NULL,
  SEQ_NO              BIGINT        GENERATED ALWAYS AS IDENTITY,
  TRAN_TYPE           VARCHAR(10)   NOT NULL,
  TRAN_DATE           DATE          NOT NULL,
  EFFECT_DATE         DATE          NOT NULL,
  POST_DATE           DATE          NOT NULL,
  VALUE_DATE          DATE          NOT NULL,
  TRAN_AMT            NUMERIC(18,2) NOT NULL,
  CR_DR_MAINT_IND     VARCHAR(2)    NOT NULL,
  PREVIOUS_BAL_AMT    NUMERIC(18,2) NOT NULL,
  ACTUAL_BAL_AMT      NUMERIC(18,2) NOT NULL,
  TFR_INTERNAL_KEY    BIGINT,
  TFR_SEQ_NO          BIGINT,
  REFERENCE           VARCHAR(64)   NOT NULL,
  ORIG_SEQ_NO         BIGINT,
  CCY                 VARCHAR(4)    NOT NULL,
  SOURCE_TYPE         VARCHAR(8),
  SOURCE_MODULE       VARCHAR(8)    NOT NULL DEFAULT 'WLT',
  TRAN_DESC           VARCHAR(200),
  NARRATIVE           VARCHAR(250),                   -- free-text memo from the originating request
  TERMINAL_ID         VARCHAR(40),
  OFFICER_ID          VARCHAR(40),
  GROUP_ID            VARCHAR(20),
  SHARD_INDEX         SMALLINT,
  METADATA            JSONB,                   -- caller-supplied open bag (≤1KB, P1-forbidden)
  CLIENT_INFO         JSONB,                   -- SP-computed snapshot (≤512B, P2-only)
  TIME_STAMP          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  CONSTRAINT pk_hist PRIMARY KEY (INTERNAL_KEY, SEQ_NO, POST_DATE),
  CONSTRAINT chk_hist_crdr CHECK (CR_DR_MAINT_IND IN ('DR','CR'))
) PARTITION BY RANGE (POST_DATE);

CREATE INDEX idx_hist_acct_date  ON WLT_TRAN_HIST(INTERNAL_KEY, POST_DATE DESC);
CREATE INDEX idx_hist_tfr        ON WLT_TRAN_HIST(TFR_INTERNAL_KEY, TFR_SEQ_NO);
CREATE INDEX idx_hist_ref        ON WLT_TRAN_HIST(REFERENCE);
CREATE INDEX idx_hist_group_date ON WLT_TRAN_HIST(GROUP_ID, POST_DATE DESC) WHERE GROUP_ID IS NOT NULL;

ALTER TABLE WLT_TRAN_HIST ALTER COLUMN METADATA    SET STORAGE EXTENDED;
ALTER TABLE WLT_TRAN_HIST ALTER COLUMN METADATA    SET COMPRESSION lz4;
ALTER TABLE WLT_TRAN_HIST ALTER COLUMN CLIENT_INFO SET STORAGE EXTENDED;
ALTER TABLE WLT_TRAN_HIST ALTER COLUMN CLIENT_INFO SET COMPRESSION lz4;

-- Initial 6 months × 32 hash partitions (manual creation Y1; pg_partman Y2+)
DO $$
DECLARE
  v_month_start DATE := date_trunc('month', CURRENT_DATE)::date;
  v_month_end   DATE;
  v_month_key   TEXT;
  v_parent      TEXT;
  v_hash        INT;
BEGIN
  FOR i IN 0..5 LOOP
    v_month_end := (v_month_start + INTERVAL '1 month')::date;
    v_month_key := to_char(v_month_start, 'YYYY_MM');
    v_parent    := 'wlt_tran_hist_' || v_month_key;
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS %I PARTITION OF WLT_TRAN_HIST FOR VALUES FROM (%L) TO (%L) PARTITION BY HASH (INTERNAL_KEY)',
      v_parent, v_month_start, v_month_end);
    FOR v_hash IN 0..31 LOOP
      EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF %I FOR VALUES WITH (MODULUS 32, REMAINDER %s)',
        v_parent || '_h' || lpad(v_hash::text, 2, '0'), v_parent, v_hash);
    END LOOP;
    v_month_start := v_month_end;
  END LOOP;
END $$;

-- ─── WLT_BATCH (GL feed) ──────────────────────────────────────────────────
CREATE TABLE WLT_BATCH (
  TRAN_KEY          BIGINT        NOT NULL,
  SEQ_NO            BIGINT        NOT NULL,
  GL_CODE           VARCHAR(32)   NOT NULL,
  CLIENT_NO         VARCHAR(48),
  ACCT_INTERNAL_KEY BIGINT,
  AMOUNT            NUMERIC(18,2) NOT NULL,
  TRAN_NATURE       VARCHAR(4)    NOT NULL,
  CCY               VARCHAR(4)    NOT NULL,
  REFERENCE         VARCHAR(64),
  NARRATIVE         VARCHAR(200),
  POST_DATE         DATE          NOT NULL,
  VALUE_DATE        DATE          NOT NULL,
  SOURCE_MODULE     VARCHAR(8)    NOT NULL DEFAULT 'WLT',
  STATUS            VARCHAR(4)    NOT NULL DEFAULT 'P',
  TIME_STAMP        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  PRIMARY KEY (TRAN_KEY, SEQ_NO),
  CONSTRAINT fk_batch_gl     FOREIGN KEY (GL_CODE)   REFERENCES FM_GL_MAST(GL_CODE),
  CONSTRAINT fk_batch_ccy    FOREIGN KEY (CCY)       REFERENCES FM_CURRENCY(CCY),
  CONSTRAINT chk_batch_nat   CHECK (TRAN_NATURE IN ('DR','CR')),
  CONSTRAINT chk_batch_amt   CHECK (AMOUNT >= 0),
  CONSTRAINT chk_batch_status CHECK (STATUS IN ('P','S','F','R'))
);
CREATE INDEX idx_batch_gl_date ON WLT_BATCH(GL_CODE, POST_DATE);
CREATE INDEX idx_batch_ref     ON WLT_BATCH(REFERENCE);
CREATE INDEX idx_batch_acct    ON WLT_BATCH(ACCT_INTERNAL_KEY, POST_DATE);
CREATE INDEX idx_batch_pending ON WLT_BATCH(POST_DATE) WHERE STATUS = 'P';

-- ─── WLT_ACCT_BAL (daily snapshot per account) ────────────────────────────
CREATE TABLE WLT_ACCT_BAL (
  INTERNAL_KEY    BIGINT        NOT NULL,
  TRAN_DATE       DATE          NOT NULL,
  ACTUAL_BAL      NUMERIC(18,2) NOT NULL,
  CALC_BAL        NUMERIC(18,2) NOT NULL,
  PREV_ACTUAL_BAL NUMERIC(18,2),
  PREV_CALC_BAL   NUMERIC(18,2),
  CREATED_AT      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  PRIMARY KEY (INTERNAL_KEY, TRAN_DATE),
  CONSTRAINT fk_bal_acct FOREIGN KEY (INTERNAL_KEY) REFERENCES WLT_ACCT(INTERNAL_KEY)
) PARTITION BY RANGE (TRAN_DATE);

DO $$
DECLARE
  v_month_start DATE := date_trunc('month', CURRENT_DATE)::date;
  v_month_end   DATE;
BEGIN
  FOR i IN 0..5 LOOP
    v_month_end := (v_month_start + INTERVAL '1 month')::date;
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS %I PARTITION OF WLT_ACCT_BAL FOR VALUES FROM (%L) TO (%L)',
      'wlt_acct_bal_' || to_char(v_month_start, 'YYYY_MM'), v_month_start, v_month_end);
    v_month_start := v_month_end;
  END LOOP;
END $$;

-- ─── WLT_NOSTRO_BAL (daily nostro recon snapshot) ─────────────────────────
CREATE TABLE WLT_NOSTRO_BAL (
  NOSTRO_ID            VARCHAR(16)   NOT NULL,
  BAL_DATE             DATE          NOT NULL,
  BANK_REPORTED_BAL    NUMERIC(18,2),
  LEDGER_BAL           NUMERIC(18,2),
  DIFF_AMT             NUMERIC(18,2) GENERATED ALWAYS AS (BANK_REPORTED_BAL - LEDGER_BAL) STORED,
  RECON_STATUS         VARCHAR(8)    NOT NULL DEFAULT 'OPEN',
  CREATED_AT           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  PRIMARY KEY (NOSTRO_ID, BAL_DATE),
  CONSTRAINT fk_nb_link  FOREIGN KEY (NOSTRO_ID) REFERENCES WLT_NOSTRO_LINK(NOSTRO_ID),
  CONSTRAINT chk_nb_st   CHECK (RECON_STATUS IN ('OPEN','MATCH','BREAK','RESOLVED'))
);


-- =============================================================================
-- §6. WLT TIER — CONTROL
-- =============================================================================

-- ─── WLT_RESTRAINTS ───────────────────────────────────────────────────────
CREATE TABLE WLT_RESTRAINTS (
  SEQ_NO            BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  INTERNAL_KEY      BIGINT,                                -- exactly one of (INTERNAL_KEY, GROUP_ID)
  GROUP_ID          VARCHAR(20),
  RESTRAINT_TYPE    VARCHAR(8)    NOT NULL,
  RESTRAINT_PURPOSE VARCHAR(16)   NOT NULL,
  PLEDGED_AMT       NUMERIC(18,2) NOT NULL DEFAULT 0,
  START_DATE        DATE          NOT NULL DEFAULT CURRENT_DATE,
  END_DATE          DATE,
  STATUS            VARCHAR(4)    NOT NULL DEFAULT 'A',
  NARRATIVE         VARCHAR(500),
  REFERENCE_DOC     VARCHAR(500),
  CREATED_AT        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  CREATED_BY        VARCHAR(40)   NOT NULL,
  REMOVED_AT        TIMESTAMPTZ,
  REMOVED_BY        VARCHAR(40),
  REMOVED_REASON    VARCHAR(500),
  CONSTRAINT fk_rstr_acct  FOREIGN KEY (INTERNAL_KEY) REFERENCES WLT_ACCT(INTERNAL_KEY),
  CONSTRAINT fk_rstr_group FOREIGN KEY (GROUP_ID)     REFERENCES WLT_ACCT_GROUP(GROUP_ID),
  CONSTRAINT chk_rstr_type   CHECK (RESTRAINT_TYPE IN ('DEBIT','CREDIT','ALL','INFO')),
  CONSTRAINT chk_rstr_status CHECK (STATUS IN ('A','R','E')),
  CONSTRAINT chk_rstr_scope  CHECK (
    (INTERNAL_KEY IS NOT NULL AND GROUP_ID IS NULL) OR
    (INTERNAL_KEY IS NULL     AND GROUP_ID IS NOT NULL)
  ),
  CONSTRAINT chk_rstr_dates   CHECK (END_DATE IS NULL OR END_DATE >= START_DATE),
  CONSTRAINT chk_rstr_pledged CHECK (PLEDGED_AMT >= 0)
);
CREATE INDEX idx_rstr_acct_active  ON WLT_RESTRAINTS(INTERNAL_KEY, STATUS) WHERE INTERNAL_KEY IS NOT NULL AND STATUS = 'A';
CREATE INDEX idx_rstr_group_active ON WLT_RESTRAINTS(GROUP_ID, STATUS)     WHERE GROUP_ID IS NOT NULL AND STATUS = 'A';
CREATE INDEX idx_rstr_end_date     ON WLT_RESTRAINTS(END_DATE, STATUS)     WHERE STATUS = 'A' AND END_DATE IS NOT NULL;

-- ─── WLT_API_MESSAGE (idempotency log) ────────────────────────────────────
CREATE TABLE WLT_API_MESSAGE (
  SEQ_NO              BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  OBJECT_REF_ID       VARCHAR(64)   NOT NULL UNIQUE,
  OBJECT_CHANNEL      VARCHAR(40),
  OBJECT_SUBJECT      VARCHAR(40),
  OBJECT_USER         VARCHAR(64),
  OBJECT_REQUEST_DATA TEXT,
  OBJECT_RESPONE_DATA TEXT,
  HTTP_STATUS         SMALLINT,
  PROCESS_STATUS      VARCHAR(8)    NOT NULL DEFAULT 'PENDING',
  OBJECT_DATE         TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  PROCESSED_AT        TIMESTAMPTZ,
  CONSTRAINT chk_api_status CHECK (PROCESS_STATUS IN ('PENDING','SUCCESS','FAILED'))
);
ALTER TABLE WLT_API_MESSAGE ALTER COLUMN OBJECT_REQUEST_DATA SET COMPRESSION lz4;
ALTER TABLE WLT_API_MESSAGE ALTER COLUMN OBJECT_RESPONE_DATA SET COMPRESSION lz4;
CREATE INDEX idx_api_date  ON WLT_API_MESSAGE(OBJECT_DATE);
CREATE INDEX idx_api_subj  ON WLT_API_MESSAGE(OBJECT_SUBJECT, PROCESS_STATUS);

-- ─── WLT_OUTBOX (transactional outbox — atomic with posting commit) ───────
CREATE TABLE WLT_OUTBOX (
  EVENT_ID            BIGINT        GENERATED ALWAYS AS IDENTITY,
  EVENT_UUID          UUID          NOT NULL DEFAULT gen_random_uuid(),
  AGGREGATE_TYPE      VARCHAR(20)   NOT NULL,
  AGGREGATE_ID        VARCHAR(64)   NOT NULL,
  EVENT_TYPE          VARCHAR(40)   NOT NULL,
  EVENT_VERSION       VARCHAR(8)    NOT NULL DEFAULT 'v1',
  PARTITION_KEY       VARCHAR(64)   NOT NULL,
  TOPIC               VARCHAR(60)   NOT NULL,
  PAYLOAD             JSONB         NOT NULL,
  HEADERS             JSONB,
  CREATED_AT          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  STATUS              VARCHAR(8)    NOT NULL DEFAULT 'PENDING',
  ATTEMPTS            SMALLINT      NOT NULL DEFAULT 0,
  LAST_ATTEMPT_AT     TIMESTAMPTZ,
  LAST_ERROR          VARCHAR(500),
  SENT_AT             TIMESTAMPTZ,
  KAFKA_OFFSET        BIGINT,
  KAFKA_PARTITION     SMALLINT,
  PRIMARY KEY (EVENT_ID, CREATED_AT),
  CONSTRAINT uk_outbox_uuid    UNIQUE (EVENT_UUID, CREATED_AT),
  CONSTRAINT chk_outbox_status CHECK (STATUS IN ('PENDING','SENT','FAILED','DEAD'))
) PARTITION BY RANGE (CREATED_AT);

DO $$
DECLARE
  v_month_start DATE := date_trunc('month', CURRENT_DATE)::date;
  v_month_end   DATE;
BEGIN
  FOR i IN 0..5 LOOP
    v_month_end := (v_month_start + INTERVAL '1 month')::date;
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS %I PARTITION OF WLT_OUTBOX FOR VALUES FROM (%L) TO (%L)',
      'wlt_outbox_' || to_char(v_month_start, 'YYYY_MM'), v_month_start, v_month_end);
    v_month_start := v_month_end;
  END LOOP;
END $$;

CREATE INDEX idx_outbox_pending ON WLT_OUTBOX(EVENT_ID) WHERE STATUS = 'PENDING';
CREATE INDEX idx_outbox_agg     ON WLT_OUTBOX(AGGREGATE_TYPE, AGGREGATE_ID);
CREATE INDEX idx_outbox_dead    ON WLT_OUTBOX(CREATED_AT) WHERE STATUS IN ('FAILED','DEAD');
ALTER TABLE WLT_OUTBOX ALTER COLUMN PAYLOAD SET STORAGE EXTENDED;
ALTER TABLE WLT_OUTBOX ALTER COLUMN PAYLOAD SET COMPRESSION lz4;

-- ─── WLT_WITHDRAW_TRACK (disbursement state machine) ──────────────────────
CREATE TABLE WLT_WITHDRAW_TRACK (
  TFR_INTERNAL_KEY    BIGINT        PRIMARY KEY,
  ACCT_NO             VARCHAR(20)   NOT NULL,
  CLIENT_NO           VARCHAR(48)   NOT NULL,
  AMOUNT              NUMERIC(18,2) NOT NULL,
  FEE_GROSS           NUMERIC(18,2) NOT NULL DEFAULT 0,
  CCY                 VARCHAR(4)    NOT NULL DEFAULT 'VND',
  EXT_PAYOUT_REF      VARCHAR(64)   NOT NULL UNIQUE,
  BENEFICIARY_BANK    VARCHAR(20)   NOT NULL,
  BENEFICIARY_ACCT_ENC BYTEA        NOT NULL,
  STATUS              VARCHAR(12)   NOT NULL DEFAULT 'SUBMITTED',
  TREASURY_BATCH_ID   VARCHAR(64),
  NAPAS_REF           VARCHAR(64),
  TREASURY_ACK_AT     TIMESTAMPTZ,
  TREASURY_FINAL_AT   TIMESTAMPTZ,
  REVERSED_AT         TIMESTAMPTZ,
  REVERSAL_TFR_KEY    BIGINT,
  FAIL_CODE           VARCHAR(40),
  FAIL_REASON         VARCHAR(500),
  SUBMITTED_AT        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  ACK_DEADLINE        TIMESTAMPTZ   NOT NULL DEFAULT (NOW() + INTERVAL '60 seconds'),
  FINAL_DEADLINE      TIMESTAMPTZ   NOT NULL DEFAULT (NOW() + INTERVAL '24 hours'),
  VERSION             INTEGER       NOT NULL DEFAULT 0,
  CONSTRAINT chk_wd_status CHECK (STATUS IN ('SUBMITTED','ACKED','DISBURSING','COMPLETED','FAILED','REVERSED'))
);
CREATE INDEX idx_wd_status        ON WLT_WITHDRAW_TRACK(STATUS)         WHERE STATUS IN ('SUBMITTED','ACKED','DISBURSING');
CREATE INDEX idx_wd_ack_overdue   ON WLT_WITHDRAW_TRACK(ACK_DEADLINE)   WHERE STATUS = 'SUBMITTED';
CREATE INDEX idx_wd_final_overdue ON WLT_WITHDRAW_TRACK(FINAL_DEADLINE) WHERE STATUS IN ('ACKED','DISBURSING');
CREATE INDEX idx_wd_acct          ON WLT_WITHDRAW_TRACK(ACCT_NO, SUBMITTED_AT DESC);

-- ─── WLT_SWEEP_LOG (sub-account sharding audit — created Y1, used later) ──
CREATE TABLE WLT_SWEEP_LOG (
  SEQ_NO               BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  GROUP_ID             VARCHAR(20)   NOT NULL,
  SHARD_ACCT_NO        VARCHAR(20)   NOT NULL,
  SETTLEMENT_ACCT_NO   VARCHAR(20)   NOT NULL,
  SWEPT_AMOUNT         NUMERIC(18,2) NOT NULL,
  SHARD_BAL_BEFORE     NUMERIC(18,2) NOT NULL,
  SHARD_BAL_AFTER      NUMERIC(18,2) NOT NULL,
  SETTLEMENT_BAL_AFTER NUMERIC(18,2) NOT NULL,
  TFR_INTERNAL_KEY     BIGINT,
  TRIGGER_TYPE         VARCHAR(16)   NOT NULL,
  TRIGGERED_BY         VARCHAR(40),
  STATUS               VARCHAR(8)    NOT NULL DEFAULT 'SUCCESS',
  ERROR_MESSAGE        VARCHAR(500),
  CREATED_AT           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  CONSTRAINT fk_sweep_group  FOREIGN KEY (GROUP_ID) REFERENCES WLT_ACCT_GROUP(GROUP_ID),
  CONSTRAINT chk_sweep_trigger CHECK (TRIGGER_TYPE IN ('PERIODIC','THRESHOLD','URGENT','EOD')),
  CONSTRAINT chk_sweep_status  CHECK (STATUS IN ('SUCCESS','CONFLICT','SKIPPED','FAILED'))
);
CREATE INDEX idx_sweep_group_time ON WLT_SWEEP_LOG(GROUP_ID, CREATED_AT DESC);
CREATE INDEX idx_sweep_shard_time ON WLT_SWEEP_LOG(SHARD_ACCT_NO, CREATED_AT DESC);


-- =============================================================================
-- §7. AUDIT — client-info change capture
-- =============================================================================

-- ─── WLT_CLIENT_AUDIT_LOG ─────────────────────────────────────────────────
CREATE TABLE WLT_CLIENT_AUDIT_LOG (
  AUDIT_ID         BIGINT       GENERATED ALWAYS AS IDENTITY,
  CLIENT_NO        VARCHAR(48)  NOT NULL,
  TABLE_NAME       VARCHAR(40)  NOT NULL,
  ROW_PK           JSONB        NOT NULL,
  OPERATION        VARCHAR(8)   NOT NULL,
  CHANGED_AT       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CHANGED_BY       VARCHAR(64)  NOT NULL,
  CHANGE_SOURCE    VARCHAR(16)  NOT NULL,
  CHANGE_REASON    VARCHAR(500),
  OLD_VALUES       JSONB,
  NEW_VALUES       JSONB,
  CHANGED_FIELDS   TEXT[]       NOT NULL,
  REQUEST_ID       VARCHAR(64),
  IP_ADDRESS       INET,
  USER_AGENT       VARCHAR(500),
  MAKER_ID         VARCHAR(64),
  CHECKER_ID       VARCHAR(64),
  APPROVAL_REF     VARCHAR(64),
  PRIMARY KEY (AUDIT_ID, CHANGED_AT),
  CONSTRAINT chk_audit_op  CHECK (OPERATION IN ('INSERT','UPDATE','DELETE')),
  CONSTRAINT chk_audit_src CHECK (CHANGE_SOURCE IN ('OPS_UI','API','EKYC','SYS_BATCH','COMPLIANCE','SP_BACKFILL'))
) PARTITION BY RANGE (CHANGED_AT);

DO $$
DECLARE
  v_month_start DATE := date_trunc('month', CURRENT_DATE)::date;
  v_month_end   DATE;
BEGIN
  FOR i IN 0..5 LOOP
    v_month_end := (v_month_start + INTERVAL '1 month')::date;
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS %I PARTITION OF WLT_CLIENT_AUDIT_LOG FOR VALUES FROM (%L) TO (%L)',
      'wlt_client_audit_log_' || to_char(v_month_start, 'YYYY_MM'), v_month_start, v_month_end);
    v_month_start := v_month_end;
  END LOOP;
END $$;

CREATE INDEX idx_caudit_client_time    ON WLT_CLIENT_AUDIT_LOG(CLIENT_NO, CHANGED_AT DESC);
CREATE INDEX idx_caudit_table_time     ON WLT_CLIENT_AUDIT_LOG(TABLE_NAME, CHANGED_AT DESC);
CREATE INDEX idx_caudit_changed_fields ON WLT_CLIENT_AUDIT_LOG USING GIN (CHANGED_FIELDS);
CREATE INDEX idx_caudit_request        ON WLT_CLIENT_AUDIT_LOG(REQUEST_ID) WHERE REQUEST_ID IS NOT NULL;

ALTER TABLE WLT_CLIENT_AUDIT_LOG ALTER COLUMN OLD_VALUES SET STORAGE EXTENDED;
ALTER TABLE WLT_CLIENT_AUDIT_LOG ALTER COLUMN OLD_VALUES SET COMPRESSION lz4;
ALTER TABLE WLT_CLIENT_AUDIT_LOG ALTER COLUMN NEW_VALUES SET STORAGE EXTENDED;
ALTER TABLE WLT_CLIENT_AUDIT_LOG ALTER COLUMN NEW_VALUES SET COMPRESSION lz4;

-- ─── Trigger function: capture every INSERT/UPDATE/DELETE on client tables ──
CREATE OR REPLACE FUNCTION fn_audit_client_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_old        JSONB;
  v_new        JSONB;
  v_diff       TEXT[];
  v_client_no  VARCHAR(48);
  v_pk         JSONB;
  v_actor      VARCHAR(64);
  v_src        VARCHAR(16);
BEGIN
  v_actor := COALESCE(current_setting('audit.actor', TRUE), session_user);
  v_src   := COALESCE(current_setting('audit.source', TRUE), 'SP_BACKFILL');

  IF TG_OP = 'INSERT' THEN
    v_old := NULL;
    v_new := to_jsonb(NEW);
    v_diff := ARRAY(SELECT jsonb_object_keys(v_new));
    v_client_no := NEW.CLIENT_NO;
  ELSIF TG_OP = 'UPDATE' THEN
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
    v_diff := ARRAY(
      SELECT k FROM jsonb_object_keys(v_new) k
       WHERE v_old->k IS DISTINCT FROM v_new->k
    );
    IF cardinality(v_diff) = 0 THEN
      RETURN NEW;
    END IF;
    v_client_no := NEW.CLIENT_NO;
  ELSIF TG_OP = 'DELETE' THEN
    v_old := to_jsonb(OLD);
    v_new := NULL;
    v_diff := ARRAY(SELECT jsonb_object_keys(v_old));
    v_client_no := OLD.CLIENT_NO;
  END IF;

  v_pk := jsonb_build_object('table', TG_TABLE_NAME, 'client_no', v_client_no);

  INSERT INTO WLT_CLIENT_AUDIT_LOG (
    CLIENT_NO, TABLE_NAME, ROW_PK, OPERATION,
    CHANGED_BY, CHANGE_SOURCE, CHANGE_REASON,
    OLD_VALUES, NEW_VALUES, CHANGED_FIELDS,
    REQUEST_ID, IP_ADDRESS, USER_AGENT,
    MAKER_ID, CHECKER_ID, APPROVAL_REF
  ) VALUES (
    v_client_no, TG_TABLE_NAME, v_pk, TG_OP,
    v_actor, v_src, current_setting('audit.reason', TRUE),
    v_old, v_new, v_diff,
    current_setting('audit.request_id', TRUE),
    NULLIF(current_setting('audit.ip', TRUE), '')::INET,
    current_setting('audit.user_agent', TRUE),
    current_setting('audit.maker_id', TRUE),
    current_setting('audit.checker_id', TRUE),
    current_setting('audit.approval_ref', TRUE)
  );

  RETURN COALESCE(NEW, OLD);
END $$;

-- Attach the trigger to wallet-owned client table
CREATE TRIGGER trg_audit_wlt_kyc
  AFTER INSERT OR UPDATE OR DELETE ON WLT_CLIENT_KYC
  FOR EACH ROW EXECUTE FUNCTION fn_audit_client_change();

-- FM_CLIENT_BANKS — audit linked-bank changes (link / set-default / unlink).
CREATE TRIGGER trg_audit_fm_client_bk       AFTER INSERT OR UPDATE OR DELETE ON FM_CLIENT_BANKS       FOR EACH ROW EXECUTE FUNCTION fn_audit_client_change();

-- Other FM-tier triggers (uncomment after coordination with FM data team):
-- CREATE TRIGGER trg_audit_fm_client       AFTER INSERT OR UPDATE OR DELETE ON FM_CLIENT             FOR EACH ROW EXECUTE FUNCTION fn_audit_client_change();
-- CREATE TRIGGER trg_audit_fm_client_indvl AFTER INSERT OR UPDATE OR DELETE ON FM_CLIENT_INDVL       FOR EACH ROW EXECUTE FUNCTION fn_audit_client_change();
-- CREATE TRIGGER trg_audit_fm_client_id    AFTER INSERT OR UPDATE OR DELETE ON FM_CLIENT_IDENTIFIERS FOR EACH ROW EXECUTE FUNCTION fn_audit_client_change();
-- CREATE TRIGGER trg_audit_fm_client_ct    AFTER INSERT OR UPDATE OR DELETE ON FM_CLIENT_CONTACT     FOR EACH ROW EXECUTE FUNCTION fn_audit_client_change();


-- =============================================================================
-- §8. VIEWS
-- =============================================================================

-- Group balance aggregate (used when sub-account sharding is enabled).
CREATE OR REPLACE VIEW v_wlt_group_balance AS
SELECT
  g.GROUP_ID,
  g.CLIENT_NO,
  g.GROUP_TYPE,
  s.ACTUAL_BAL                                        AS settlement_bal,
  s.ACTUAL_BAL - s.TOTAL_RESTRAINED_AMT               AS settlement_available,
  COALESCE(SUM(sh.ACTUAL_BAL), 0)                     AS shards_total,
  s.ACTUAL_BAL + COALESCE(SUM(sh.ACTUAL_BAL), 0)      AS total_balance,
  s.ACTUAL_BAL - s.TOTAL_RESTRAINED_AMT
    + COALESCE(SUM(sh.ACTUAL_BAL - sh.TOTAL_RESTRAINED_AMT), 0) AS total_available,
  COUNT(sh.INTERNAL_KEY)                              AS active_shards,
  GREATEST(s.LAST_TRAN_DATE, MAX(sh.LAST_TRAN_DATE))  AS last_tran_date
FROM WLT_ACCT_GROUP g
JOIN WLT_ACCT s  ON s.GROUP_ID = g.GROUP_ID AND s.ACCT_ROLE = 'SETTLEMENT'
LEFT JOIN WLT_ACCT sh ON sh.GROUP_ID = g.GROUP_ID AND sh.ACCT_ROLE = 'SHARD'
GROUP BY g.GROUP_ID, g.CLIENT_NO, g.GROUP_TYPE,
         s.ACTUAL_BAL, s.TOTAL_RESTRAINED_AMT, s.LAST_TRAN_DATE;

-- Effective restraints (acct-level + group-level merged for posting checks).
CREATE OR REPLACE VIEW v_wlt_active_restraints_effective AS
SELECT
  COALESCE(r.INTERNAL_KEY, a.INTERNAL_KEY) AS internal_key,
  r.SEQ_NO                                  AS restraint_id,
  r.GROUP_ID,
  r.RESTRAINT_TYPE,
  r.RESTRAINT_PURPOSE,
  r.PLEDGED_AMT,
  r.STATUS,
  r.START_DATE, r.END_DATE,
  CASE WHEN r.GROUP_ID IS NOT NULL THEN 'GROUP' ELSE 'ACCT' END AS scope
FROM WLT_RESTRAINTS r
LEFT JOIN WLT_ACCT a ON a.GROUP_ID = r.GROUP_ID
WHERE r.STATUS = 'A'
  AND CURRENT_DATE BETWEEN r.START_DATE AND COALESCE(r.END_DATE, DATE '9999-12-31');

-- Masked-PII view for general app access (replace plaintext PHONE_NO etc.)
CREATE OR REPLACE VIEW v_kyc_masked AS
SELECT
  KYC_ID, CLIENT_NO,
  '09xxxxx' || right(encode(PHONE_NO_HASH, 'hex'), 3) AS phone_masked,  -- placeholder; replace with decrypt + mask in real impl
  KYC_TIER, STATUS, RISK_LEVEL, VERIFIED_AT
FROM WLT_CLIENT_KYC;

-- Masked client profile (for GET /v1/clients/:client_no via wallet_app).
-- Runs with the view OWNER's privileges (security_invoker off, PG default), so
-- wallet_app reads the masked output WITHOUT direct SELECT on raw CLIENT_NAME /
-- GLOBAL_ID (those grants are deliberately withheld — see §10). PII shown masked;
-- the unmasked profile is GET /v1/ops/clients/:client_no via wallet_pii_ro.
CREATE OR REPLACE VIEW v_client_masked AS
SELECT
  c.CLIENT_NO,
  regexp_replace(c.CLIENT_NAME, '(^.).*(.$)', '\1***\2')        AS client_name_masked,
  c.CLIENT_TYPE,
  c.GLOBAL_ID_TYPE,
  CASE WHEN c.GLOBAL_ID IS NULL THEN NULL
       ELSE '****' || right(c.GLOBAL_ID, 4) END                AS global_id_masked,
  c.COUNTRY_LOC, c.COUNTRY_CITIZEN, c.CLIENT_GRP, c.ACCT_EXEC,
  c.STATUS,
  i.BIRTH_DATE, i.SEX, i.RESIDENT_STATUS,
  k.KYC_TIER,
  k.STATUS                                                     AS kyc_status,
  k.RISK_LEVEL,
  CASE WHEN k.PHONE_NO_HASH IS NULL THEN NULL
       ELSE '09xxxxx' || right(encode(k.PHONE_NO_HASH, 'hex'), 3) END AS phone_masked,
  k.VERIFIED_AT
FROM FM_CLIENT c
LEFT JOIN FM_CLIENT_INDVL i ON i.CLIENT_NO = c.CLIENT_NO
LEFT JOIN LATERAL (
  SELECT k2.KYC_TIER, k2.STATUS, k2.RISK_LEVEL, k2.PHONE_NO_HASH, k2.VERIFIED_AT
    FROM WLT_CLIENT_KYC k2
   WHERE k2.CLIENT_NO = c.CLIENT_NO
   ORDER BY k2.KYC_ID DESC
   LIMIT 1
) k ON true;


-- =============================================================================
-- §8b. AUDIT COLUMN OVERLAY — adds 5 standard audit cols to every base table
-- =============================================================================
--
-- Standard 5 columns added to every public.* base table (skipping leaf
-- partitions — ALTER on partitioned parent auto-propagates):
--   CHANNEL     VARCHAR(20)              — source channel: MOBILE/OPSUI/API/EKYC/SYS/BATCH/PARTNER
--   CREATED_AT  TIMESTAMPTZ NOT NULL     — set once on INSERT, immutable after
--   CREATED_BY  VARCHAR(64) NOT NULL     — actor at INSERT, pulled from GUC `audit.actor`
--   UPDATED_AT  TIMESTAMPTZ NOT NULL     — bumped on every UPDATE via trigger
--   UPDATED_BY  VARCHAR(64) NOT NULL     — actor at UPDATE, pulled from GUC `audit.actor`
--
-- Application contract — set these at the start of every business TX:
--   SET LOCAL audit.actor   = '<user_id|system_id>';
--   SET LOCAL audit.channel = 'MOBILE';
-- Trigger fn_set_audit_columns() reads them on every INSERT/UPDATE.
--
-- Storage cost per row: ~50 bytes (channel ~5 + 2× ts 16 + 2× varchar ~30).
-- For WLT_TRAN_HIST at Y5 ~9B rows: ~450 GB extra. UPDATED_* on append-only
-- tables (TRAN_HIST, BATCH, AUDIT_LOG, SWEEP_LOG) is wasted ~150 GB Y5 — keep
-- for uniformity; drop selectively if storage becomes a concern.

DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT t.tablename
      FROM pg_tables t
     WHERE t.schemaname = 'public'
       AND t.tablename NOT LIKE 'pg_%'
       AND NOT EXISTS (
         SELECT 1 FROM pg_inherits i
          WHERE i.inhrelid = (t.schemaname||'.'||t.tablename)::regclass
       )
     ORDER BY t.tablename
  LOOP
    EXECUTE format($f$
      ALTER TABLE %I
        ADD COLUMN IF NOT EXISTS CHANNEL    VARCHAR(20),
        ADD COLUMN IF NOT EXISTS CREATED_AT TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        ADD COLUMN IF NOT EXISTS CREATED_BY VARCHAR(64) NOT NULL DEFAULT 'SYSTEM',
        ADD COLUMN IF NOT EXISTS UPDATED_AT TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        ADD COLUMN IF NOT EXISTS UPDATED_BY VARCHAR(64) NOT NULL DEFAULT 'SYSTEM'
    $f$, r.tablename);
  END LOOP;
END $$;

-- Trigger function: BEFORE INSERT OR UPDATE.
--   INSERT: pull CHANNEL + CREATED_BY from audit.* GUCs; CREATED_AT = clock_timestamp();
--           UPDATED_* mirror CREATED_* until first UPDATE.
--   UPDATE: bump UPDATED_AT to clock_timestamp(), pull UPDATED_BY from audit.actor;
--           CREATED_* / CHANNEL preserved from OLD (immutable post-INSERT).
-- Uses clock_timestamp() (per-statement) instead of NOW() (per-TX) so
-- multiple updates within one TX get distinct timestamps.

CREATE OR REPLACE FUNCTION fn_set_audit_columns()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
  v_actor   VARCHAR(64);
  v_channel VARCHAR(20);
  v_now     TIMESTAMPTZ := clock_timestamp();
BEGIN
  v_actor   := COALESCE(NULLIF(current_setting('audit.actor',   TRUE), ''), session_user);
  v_channel := COALESCE(NULLIF(current_setting('audit.channel', TRUE), ''), 'SYSTEM');

  IF TG_OP = 'INSERT' THEN
    NEW.CHANNEL    := COALESCE(NEW.CHANNEL,    v_channel);
    NEW.CREATED_BY := COALESCE(NULLIF(NEW.CREATED_BY, 'SYSTEM'), v_actor);
    NEW.CREATED_AT := COALESCE(NEW.CREATED_AT, v_now);
    NEW.UPDATED_BY := NEW.CREATED_BY;
    NEW.UPDATED_AT := NEW.CREATED_AT;
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.UPDATED_AT := v_now;
    NEW.UPDATED_BY := v_actor;
    NEW.CREATED_AT := OLD.CREATED_AT;
    NEW.CREATED_BY := OLD.CREATED_BY;
    NEW.CHANNEL    := OLD.CHANNEL;
  END IF;
  RETURN NEW;
END $$;

-- Attach trigger to every base table that has UPDATED_AT
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT DISTINCT t.tablename
      FROM pg_tables t
      JOIN information_schema.columns c
        ON c.table_schema = t.schemaname
       AND c.table_name   = t.tablename
       AND c.column_name  = 'updated_at'
     WHERE t.schemaname = 'public'
       AND NOT EXISTS (
         SELECT 1 FROM pg_inherits i
          WHERE i.inhrelid = (t.schemaname||'.'||t.tablename)::regclass
       )
     ORDER BY t.tablename
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit_cols ON %I', r.tablename);
    EXECUTE format(
      'CREATE TRIGGER trg_audit_cols BEFORE INSERT OR UPDATE ON %I
         FOR EACH ROW EXECUTE FUNCTION fn_set_audit_columns()',
      r.tablename);
  END LOOP;
END $$;


-- =============================================================================
-- §9. PER-TABLE TUNINGS  (critical for 20 TPS sustainability)
-- =============================================================================
--
-- Note: PG does NOT allow storage parameters on partitioned parent tables;
-- they must be applied to each leaf partition. We do this in two passes:
-- (a) regular tables — direct ALTER, (b) partitioned tables — DO loop over leaves.

-- (a) Regular (non-partitioned) tables
ALTER TABLE WLT_ACCT           SET (fillfactor = 80,                            -- enable HOT updates
                                    autovacuum_vacuum_scale_factor = 0.02,
                                    autovacuum_vacuum_cost_limit = 2000);
ALTER TABLE WLT_BATCH          SET (autovacuum_vacuum_insert_scale_factor = 0.01);
ALTER TABLE WLT_WITHDRAW_TRACK SET (fillfactor = 80);

-- (b) Leaf partitions of partitioned tables (TRAN_HIST × 32 hash, OUTBOX,
-- ACCT_BAL, CLIENT_AUDIT_LOG). Re-apply for every new monthly partition added
-- later — the partition-creation cron job should run the same loop.
DO $$
DECLARE
  r RECORD;
BEGIN
  -- TRAN_HIST leaves: insert-heavy → aggressive insert-vacuum
  FOR r IN
    SELECT c.oid::regclass::text AS tbl
      FROM pg_class c
     WHERE c.relkind = 'r'
       AND c.relname LIKE 'wlt_tran_hist_%'
  LOOP
    EXECUTE format('ALTER TABLE %s SET (autovacuum_vacuum_insert_scale_factor = 0.01)', r.tbl);
  END LOOP;

  -- OUTBOX leaves: insert + 1 status update → fillfactor + aggressive vacuum
  FOR r IN
    SELECT c.oid::regclass::text AS tbl
      FROM pg_class c
     WHERE c.relkind = 'r'
       AND c.relname LIKE 'wlt_outbox_%'
  LOOP
    EXECUTE format('ALTER TABLE %s SET (fillfactor = 90, autovacuum_vacuum_scale_factor = 0.02)', r.tbl);
  END LOOP;

  -- ACCT_BAL leaves: daily upsert per account
  FOR r IN
    SELECT c.oid::regclass::text AS tbl
      FROM pg_class c
     WHERE c.relkind = 'r'
       AND c.relname LIKE 'wlt_acct_bal_%'
  LOOP
    EXECUTE format('ALTER TABLE %s SET (fillfactor = 85, autovacuum_vacuum_insert_scale_factor = 0.05)', r.tbl);
  END LOOP;

  -- CLIENT_AUDIT_LOG leaves: insert-only
  FOR r IN
    SELECT c.oid::regclass::text AS tbl
      FROM pg_class c
     WHERE c.relkind = 'r'
       AND c.relname LIKE 'wlt_client_audit_log_%'
  LOOP
    EXECUTE format('ALTER TABLE %s SET (autovacuum_vacuum_insert_scale_factor = 0.02)', r.tbl);
  END LOOP;
END $$;


-- =============================================================================
-- §10. PERMISSIONS  (locked down per §8.3 PII regime)
-- =============================================================================

-- Schema-level
GRANT USAGE ON SCHEMA public TO wallet_app, wallet_pii_ro;

-- wallet_app: DML on WLT, SELECT on FM (via masked view)
GRANT SELECT, INSERT, UPDATE ON
  WLT_ACCT, WLT_ACCT_BAL, WLT_TRAN_HIST, WLT_BATCH,
  WLT_RESTRAINTS, WLT_API_MESSAGE, WLT_OUTBOX,
  WLT_WITHDRAW_TRACK, WLT_NOSTRO_BAL, WLT_SWEEP_LOG
TO wallet_app;

GRANT SELECT ON
  WLT_ACCT_TYPE, WLT_ACCT_GROUP, WLT_TRAN_DEF, WLT_GL_MAP,
  WLT_NOSTRO_LINK,
  FM_CURRENCY, FM_GL_MAST, FM_NOS_VOS,
  v_wlt_group_balance, v_wlt_active_restraints_effective, v_kyc_masked, v_client_masked
TO wallet_app;

-- wallet_app does NOT directly INSERT into client tables — SPs use SECURITY DEFINER.
-- wallet_app does NOT see raw PHONE_NO/EMAIL — only v_kyc_masked.
REVOKE ALL ON WLT_CLIENT_KYC, FM_CLIENT, FM_CLIENT_INDVL, FM_CLIENT_CONTACT, FM_CLIENT_BANKS, FM_CLIENT_IDENTIFIERS
  FROM wallet_app;
GRANT SELECT (CLIENT_NO, CLIENT_TYPE, COUNTRY_LOC, COUNTRY_CITIZEN, STATUS, CLIENT_GRP, ACCT_EXEC) ON FM_CLIENT TO wallet_app;
GRANT SELECT (CLIENT_NO, BIRTH_DATE, RESIDENT_STATUS, SEX) ON FM_CLIENT_INDVL TO wallet_app;

-- Audit log: SECURITY DEFINER function only — no direct INSERT/UPDATE/DELETE.
REVOKE INSERT, UPDATE, DELETE ON WLT_CLIENT_AUDIT_LOG FROM wallet_app, wallet_pii_ro, PUBLIC;
GRANT  SELECT ON WLT_CLIENT_AUDIT_LOG TO wallet_pii_ro;

-- wallet_pii_ro: full read access, every P1 read appended to WLT_PII_ACCESS_LOG by application
GRANT SELECT ON ALL TABLES IN SCHEMA public TO wallet_pii_ro;

-- Sequences (so wallet_app can call nextval('seq_tfr'))
GRANT USAGE, SELECT ON SEQUENCE seq_tfr TO wallet_app;


-- =============================================================================
-- §11. SEED DATA — minimal so SPs can run end-to-end
-- =============================================================================

-- Currency: VND only Y1
INSERT INTO FM_CURRENCY (CCY, CCY_DESC, DECI_PLACES, DAY_BASIS) VALUES
  ('VND', 'Vietnam Dong', 0, 365);  -- VND: 0 decimal places (round to đồng)

-- GL chart of accounts — minimal set for posting + fee/VAT/nostro
INSERT INTO FM_GL_MAST (GL_CODE, GL_CODE_DESC, GL_CODE_TYPE, BSPL_TYPE, GL_TYPE) VALUES
  ('101',         'Cash & equivalents (parent)',                'A', 'B', 'CASH'),
  ('101.02',      'Nostro accounts (parent)',                   'A', 'B', 'CASH'),
  ('101.02.001',  'Nostro @ Partner Bank — TKĐBTT',             'A', 'B', 'NOSTRO'),
  ('201',         'Customer liabilities (parent)',              'L', 'B', 'LIAB'),
  ('201.01',      'Customer wallets (parent)',                  'L', 'B', 'LIAB'),
  ('201.01.001',  'Customer Wallet — Consumer',                 'L', 'B', 'LIAB'),
  ('201.02',      'Merchant wallets (parent)',                  'L', 'B', 'LIAB'),
  ('201.02.001',  'Merchant Wallet',                            'L', 'B', 'LIAB'),
  ('203',         'Tax payable (parent)',                       'L', 'B', 'TAX'),
  ('203.01',      'VAT output payable',                         'L', 'B', 'TAX'),
  ('401',         'Fee revenue (parent)',                       'I', 'P', 'REV'),
  ('401.01',      'Transfer/withdraw fee revenue',              'I', 'P', 'REV'),
  ('401.02',      'Merchant withdraw fee revenue',              'I', 'P', 'REV'),
  ('401.03',      'Merchant discount rate (MDR)',               'I', 'P', 'REV');

-- Set parent relationships
UPDATE FM_GL_MAST SET CONTROL_GL_CODE = '101'    WHERE GL_CODE IN ('101.02');
UPDATE FM_GL_MAST SET CONTROL_GL_CODE = '101.02' WHERE GL_CODE = '101.02.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE = '201'    WHERE GL_CODE IN ('201.01','201.02');
UPDATE FM_GL_MAST SET CONTROL_GL_CODE = '201.01' WHERE GL_CODE = '201.01.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE = '201.02' WHERE GL_CODE = '201.02.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE = '203'    WHERE GL_CODE = '203.01';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE = '401'    WHERE GL_CODE IN ('401.01','401.02','401.03');

-- Wallet type classifications
INSERT INTO WLT_ACCT_TYPE (ACCT_TYPE, ACCT_TYPE_DESC, GL_CODE_LIAB, PROD_ID, DAILY_LIMIT, MONTHLY_LIMIT) VALUES
  ('CONSUMER', 'Consumer wallet',  '201.01.001', 'WLT-CONS',  20000000,  100000000),
  ('MERCHANT', 'Merchant wallet',  '201.02.001', 'WLT-MERCH', 500000000, 5000000000);

-- Wallet event → GL mapping
INSERT INTO WLT_GL_MAP (ACCT_TYPE, EVENT_TYPE, GL_CODE, GL_DESC) VALUES
  ('CONSUMER', 'LIABILITY',   '201.01.001', 'Customer Wallet — Consumer'),
  ('CONSUMER', 'TOPUP_DR',    '101.02.001', 'Nostro @ Bank'),
  ('CONSUMER', 'WITHDRAW_CR', '101.02.001', 'Nostro @ Bank'),
  ('CONSUMER', 'FEE_CR',      '401.01',     'Transfer/withdraw fee revenue'),
  ('CONSUMER', 'VAT_CR',      '203.01',     'VAT output payable'),
  ('MERCHANT', 'LIABILITY',   '201.02.001', 'Merchant Wallet'),
  ('MERCHANT', 'WITHDRAW_CR', '101.02.001', 'Nostro @ Bank'),
  ('MERCHANT', 'MDR_CR',      '401.03',     'Merchant discount rate'),
  ('MERCHANT', 'FEE_CR',      '401.02',     'Merchant withdraw fee revenue'),
  ('MERCHANT', 'VAT_CR',      '203.01',     'VAT output payable');

-- Transaction definitions with fee + VAT
INSERT INTO WLT_TRAN_DEF
 (TRAN_TYPE, TRAN_DESC,              CR_DR_MAINT_IND, REVERSAL_TRAN_TYPE,
  CHECK_FUND_IND, CHECK_RESTRAINT_IND, SOURCE_TYPE, CONTRA_GL_CODE,
  MIN_TRAN_AMT, MAX_TRAN_AMT, AUTO_APPROVAL, NARRATIVE, STATUS,
  FEE_TYPE, FEE_AMT, FEE_RATE, FEE_MIN, FEE_MAX, VAT_RATE,
  FEE_GL_CODE, VAT_GL_CODE, FEE_TRAN_TYPE)
VALUES
 ('TOPUP',  'Top-up from bank',        'CR', 'RVTPUP', 'N','N','BANK',   '101.02.001',
  10000, 500000000, 'Y', 'Topup', 'A',
  'NONE',    0,      0,      0,    0,        0.00, NULL,        NULL,        NULL),
 ('TRFOUT', 'Internal transfer out',   'DR', 'RVTRF',  'Y','Y','MOBILE', NULL,
  1000, 100000000, 'Y', 'Transfer', 'A',
  'FIXED',   5500,   0,      0,    0,        0.10, '401.01',    '203.01',    'FEETRF'),
 ('TRFIN',  'Internal transfer in',    'CR', 'RVTRF',  'N','N','MOBILE', NULL,
  1000, 100000000, 'Y', 'Transfer', 'A',
  'NONE',    0,      0,      0,    0,        0.00, NULL,        NULL,        NULL),
 ('WDRAW',  'Withdraw to bank',        'DR', 'RVWD',   'Y','Y','MOBILE', '101.02.001',
  50000, 200000000, 'Y', 'Withdraw', 'A',
  'PERCENT', 0,      0.001,  11000, 55000,   0.10, '401.01',    '203.01',    'FEEWD'),
 ('FEETRF', 'Fee for transfer',        'DR', 'RVFEE',  'N','N','SYS',    '401.01',
  0,      10000000, 'Y', 'Fee', 'A',
  'NONE',    0,      0,      0,    0,        0.00, NULL,        NULL,        NULL),
 ('FEEWD',  'Fee for withdraw',        'DR', 'RVFEE',  'N','N','SYS',    '401.01',
  0,      10000000, 'Y', 'Fee', 'A',
  'NONE',    0,      0,      0,    0,        0.00, NULL,        NULL,        NULL),
 ('RVTPUP', 'Reverse topup',           'DR', NULL,     'N','N','SYS',    '101.02.001',
  0,      500000000, 'Y', 'Reversal', 'A',
  'NONE',    0,      0,      0,    0,        0.00, NULL,        NULL,        NULL),
 ('RVTRF',  'Reverse transfer',        'CR', NULL,     'N','N','SYS',    NULL,
  0,      100000000, 'Y', 'Reversal', 'A',
  'NONE',    0,      0,      0,    0,        0.00, NULL,        NULL,        NULL),
 ('RVWD',   'Reverse withdraw',        'CR', NULL,     'N','N','SYS',    '101.02.001',
  0,      200000000, 'Y', 'Reversal', 'A',
  'NONE',    0,      0,      0,    0,        0.00, NULL,        NULL,        NULL),
 ('RVFEE',  'Reverse fee',             'CR', NULL,     'N','N','SYS',    '401.01',
  0,      10000000, 'Y', 'Reversal', 'A',
  'NONE',    0,      0,      0,    0,        0.00, NULL,        NULL,        NULL);

-- Sub-account sharding tran types (created Y1, used when sharding enabled).
INSERT INTO WLT_TRAN_DEF
 (TRAN_TYPE, TRAN_DESC,                CR_DR_MAINT_IND, REVERSAL_TRAN_TYPE,
  CHECK_FUND_IND, CHECK_RESTRAINT_IND, SOURCE_TYPE, CONTRA_GL_CODE,
  MIN_TRAN_AMT, MAX_TRAN_AMT, AUTO_APPROVAL, NARRATIVE, STATUS,
  FEE_TYPE, FEE_AMT, FEE_RATE, FEE_MIN, FEE_MAX, VAT_RATE,
  FEE_GL_CODE, VAT_GL_CODE, FEE_TRAN_TYPE)
VALUES
 ('SWEEPO', 'Sweep out from shard',       'DR','RVSWP', 'N','N','SYS', NULL,
  0, 1000000000, 'Y', 'Sweep', 'A',
  'NONE', 0,0,0,0, 0.00, NULL, NULL, NULL),
 ('SWEEPI', 'Sweep in to settlement',     'CR','RVSWP', 'N','N','SYS', NULL,
  0, 1000000000, 'Y', 'Sweep', 'A',
  'NONE', 0,0,0,0, 0.00, NULL, NULL, NULL),
 ('RVSWP',  'Reverse sweep',              'CR', NULL,   'N','N','SYS', NULL,
  0, 1000000000, 'Y', 'Reversal', 'A',
  'NONE', 0,0,0,0, 0.00, NULL, NULL, NULL),
 ('MERCHWD','Merchant withdraw',          'DR','RVMWD', 'Y','Y','SYS', '101.02.001',
  50000, 2000000000, 'Y', 'Withdraw', 'A',
  'PERCENT', 0, 0.0005, 22000, 110000, 0.10, '401.02', '203.01', 'FEEMW'),
 ('FEEMW',  'Fee merchant WD',            'DR','RVFEE', 'N','N','SYS', '401.02',
  0, 10000000, 'Y', 'Fee', 'A',
  'NONE', 0,0,0,0, 0.00, NULL, NULL, NULL),
 ('RVMWD',  'Reverse merchant WD',        'CR', NULL,   'N','N','SYS', '101.02.001',
  0, 2000000000, 'Y', 'Reversal', 'A',
  'NONE', 0,0,0,0, 0.00, NULL, NULL, NULL);


COMMIT;

-- =============================================================================
-- POST-DEPLOY CHECKS  (run these manually after deploy)
-- =============================================================================
--
-- 1. Verify partitions exist:
--    SELECT inhparent::regclass, inhrelid::regclass
--      FROM pg_inherits
--     WHERE inhparent IN ('wlt_tran_hist'::regclass, 'wlt_acct_bal'::regclass,
--                         'wlt_outbox'::regclass, 'wlt_client_audit_log'::regclass)
--     ORDER BY inhparent::text, inhrelid::text;
--
-- 2. Verify seed counts:
--    SELECT 'FM_CURRENCY' tbl, count(*) FROM FM_CURRENCY UNION ALL
--    SELECT 'FM_GL_MAST',  count(*) FROM FM_GL_MAST  UNION ALL
--    SELECT 'WLT_ACCT_TYPE', count(*) FROM WLT_ACCT_TYPE UNION ALL
--    SELECT 'WLT_TRAN_DEF',  count(*) FROM WLT_TRAN_DEF UNION ALL
--    SELECT 'WLT_GL_MAP',    count(*) FROM WLT_GL_MAP;
--
-- 3. Verify trigger attached:
--    SELECT tgname, tgrelid::regclass FROM pg_trigger
--     WHERE tgname LIKE 'trg_audit_%' AND NOT tgisinternal;
--
-- 4. Verify role grants:
--    \dp WLT_ACCT
--    \dp WLT_CLIENT_KYC
--
-- 5. Verify per-table tunings:
--    SELECT relname, reloptions FROM pg_class
--     WHERE relname IN ('wlt_acct','wlt_tran_hist','wlt_batch','wlt_outbox','wlt_withdraw_track');
--
-- =============================================================================
-- END OF SCHEMA
-- =============================================================================
