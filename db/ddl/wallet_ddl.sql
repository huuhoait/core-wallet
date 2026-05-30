-- =============================================================================
-- wallet_ddl.sql — Complete ERD DDL for Core Wallet System
-- =============================================================================
-- Target:    PostgreSQL 17+
-- Version:   1.0  (2026-05-29)
-- Companion: wallet_DLD.md v1.6.6, wallet_HLD_20tps.md v1.0
-- Run order:
--   1. Create database + schemas (optional: core_fm, core_wlt)
--   2. Run this file end-to-end
--   3. Run wallet_seed.sql for operational seed + test data
--
-- Conventions:
--   VARCHAR(n)    = bounded string
--   TEXT          = unbounded payload (auto TOAST)
--   BIGINT        = 64-bit integer
--   SMALLINT      = 16-bit integer
--   NUMERIC(p,s)  = exact decimal for money/rates
--   DATE          = calendar date (no time)
--   TIMESTAMPTZ   = instant with timezone
--   IDENTITY      = auto-increment (PG17 supports on partitioned tables)
--   Sequence      = shared value across multiple rows (e.g. TFR_INTERNAL_KEY)
-- =============================================================================


-- =============================================================================
-- ERD — Entity Relationship Diagram (mermaid)
-- =============================================================================
-- Paste the block below into any mermaid renderer to visualise the full ERD.
--
-- ```mermaid
-- erDiagram
--     %% ══════════════════════════════════════════════════
--     %% FM layer — Foundation Master (read-only from WLT)
--     %% ══════════════════════════════════════════════════
--     FM_CLIENT ||--o{ FM_CLIENT_INDVL          : "extends (individual)"
--     FM_CLIENT ||--o{ FM_CLIENT_IDENTIFIERS    : "IDs"
--     FM_CLIENT ||--o{ FM_CLIENT_CONTACT        : "contacts"
--     FM_CLIENT ||--o{ FM_CLIENT_BANKS          : "linked banks"
--     FM_CLIENT ||--o{ WLT_CLIENT_KYC           : "KYC info"
--     FM_CLIENT ||--o{ WLT_ACCT                 : "owns wallet"
--     FM_CLIENT ||--o{ WLT_CLIENT_AUDIT_LOG     : "field-level change history"
--     FM_CURRENCY ||--o{ WLT_ACCT               : "CCY"
--     FM_GL_MAST  ||--o{ WLT_ACCT_TYPE          : "liability GL"
--     FM_GL_MAST  ||--o{ WLT_BATCH              : "GL feed target"
--     FM_GL_MAST  ||--o{ WLT_GL_MAP             : "GL ref"
--     FM_NOS_VOS  ||--o{ WLT_NOSTRO_LINK        : "links to wallet ledger"
--
--     %% ══════════════════════════════════════════════════
--     %% WLT layer — Wallet transactional
--     %% ══════════════════════════════════════════════════
--     WLT_ACCT_TYPE  ||--o{ WLT_ACCT             : "classifies"
--     WLT_ACCT_GROUP ||--o{ WLT_ACCT             : "contains shards + settlement"
--     WLT_ACCT_GROUP ||--o{ WLT_SWEEP_LOG        : "sweep audit"
--     WLT_ACCT_GROUP ||--o{ WLT_RESTRAINTS       : "group-level scope"
--     WLT_ACCT       ||--o{ WLT_ACCT_BAL         : "daily snapshot"
--     WLT_ACCT       ||--o{ WLT_TRAN_HIST        : "posts"
--     WLT_ACCT       ||--o{ WLT_RESTRAINTS       : "acct-level scope"
--     WLT_ACCT       ||--o{ WLT_STMT_DETAIL      : "appears on"
--     WLT_TRAN_DEF   ||--o{ WLT_TRAN_HIST        : "type ref"
--     WLT_TRAN_HIST  ||--o{ WLT_BATCH            : "GL entries"
--     WLT_TRAN_HIST  ||--o{ WLT_OUTBOX           : "emits event (same TX)"
--     WLT_TRAN_HIST  ||--|| WLT_WITHDRAW_TRACK   : "withdraw disbursement state"
--     WLT_NOSTRO_LINK ||--o{ WLT_NOSTRO_BAL      : "daily balance"
--     WLT_NOSTRO_BAL  ||--o{ WLT_RECON_BREAK     : "break vs ledger"
--     WLT_API_MESSAGE ||--o{ WLT_TRAN_HIST       : "originates"
--     WLT_API_MESSAGE ||--o{ WLT_API_TRACE       : "trace"
--     WLT_CLIENT_KYC  ||--o{ WLT_CLIENT_AUDIT_LOG : "field-level change history"
--
--     %% ══════════════════════════════════════════════════
--     %% Entity attributes
--     %% ══════════════════════════════════════════════════
--     FM_CLIENT {
--         VARCHAR CLIENT_NO PK
--         VARCHAR GLOBAL_ID UK
--         VARCHAR GLOBAL_ID_TYPE
--         VARCHAR CLIENT_NAME
--         VARCHAR CLIENT_SHORT
--         VARCHAR CLIENT_TYPE
--         VARCHAR COUNTRY_LOC
--         VARCHAR COUNTRY_CITIZEN
--         VARCHAR COUNTRY_RISK
--         VARCHAR ACCT_EXEC
--         VARCHAR TAX_FILE_NO
--         VARCHAR TAXABLE_IND
--         VARCHAR NON_RESIDENT_CTRL
--     }
--
--     FM_CLIENT_INDVL {
--         VARCHAR CLIENT_NO PK_FK
--         VARCHAR SURNAME
--         VARCHAR GIVEN_NAME_1
--         DATE    BIRTH_DATE
--         VARCHAR SEX
--         VARCHAR RESIDENT_STATUS
--         VARCHAR OCCUPATION_CODE
--     }
--
--     FM_CLIENT_IDENTIFIERS {
--         VARCHAR CLIENT_NO PK_FK
--         VARCHAR GLOBAL_ID PK
--         VARCHAR GLOBAL_ID_TYPE PK
--         DATE    DT_OF_ISSUANCE
--         DATE    EXPIRY_DATE
--         VARCHAR NATIONALITY
--         SMALLINT IS_CURRENT
--     }
--
--     FM_CLIENT_CONTACT {
--         BIGINT  CONTACT_ID PK
--         VARCHAR CLIENT_NO FK
--         VARCHAR CONTACT_TYPE
--         VARCHAR CONTACT_VALUE
--         SMALLINT IS_PRIMARY
--         SMALLINT IS_VERIFIED
--     }
--
--     FM_CLIENT_BANKS {
--         BIGINT  LINK_ID PK
--         VARCHAR CLIENT_NO FK
--         VARCHAR BANK_CODE
--         VARCHAR BANK_NAME
--         VARCHAR ACCT_NO_ENC
--         VARCHAR ACCT_HOLDER_NAME
--         SMALLINT IS_DEFAULT
--         VARCHAR STATUS
--     }
--
--     FM_CURRENCY {
--         VARCHAR CCY PK
--         VARCHAR CCY_DESC
--         SMALLINT DECI_PLACES
--         SMALLINT DAY_BASIS
--         VARCHAR CCY_GROUP
--     }
--
--     FM_GL_MAST {
--         VARCHAR GL_CODE PK
--         VARCHAR GL_CODE_DESC
--         VARCHAR GL_CODE_TYPE
--         VARCHAR CONTROL_GL_CODE FK
--         VARCHAR BSPL_TYPE
--         VARCHAR GL_TYPE
--     }
--
--     FM_NOS_VOS {
--         BIGINT  NOS_VOS_NO PK
--         VARCHAR ACCT_TYPE
--         VARCHAR CCY FK
--         VARCHAR CLIENT_NO
--         VARCHAR GL_CODE FK
--         VARCHAR ACCT_NO
--         BIGINT  INTERNAL_KEY
--     }
--
--     WLT_CLIENT_KYC {
--         BIGINT  KYC_ID PK
--         VARCHAR CLIENT_NO FK
--         VARCHAR PHONE_NO UK
--         VARCHAR KYC_TIER
--         VARCHAR EKYC_PROVIDER
--         VARCHAR EKYC_REF
--         NUMERIC FACE_MATCH_SCORE
--         VARCHAR LIVENESS_RESULT
--         VARCHAR DOC_URL
--         VARCHAR STATUS
--         TIMESTAMPTZ VERIFIED_AT
--         VARCHAR VERIFIED_BY
--     }
--
--     WLT_ACCT_TYPE {
--         VARCHAR ACCT_TYPE PK
--         VARCHAR ACCT_TYPE_DESC
--         VARCHAR GL_CODE_LIAB FK
--         VARCHAR PROD_ID
--         NUMERIC DAILY_LIMIT
--         NUMERIC MONTHLY_LIMIT
--         VARCHAR INT_BEARING
--     }
--
--     WLT_ACCT_GROUP {
--         VARCHAR GROUP_ID PK
--         VARCHAR CLIENT_NO FK
--         VARCHAR GROUP_TYPE
--         SMALLINT SHARD_COUNT
--         VARCHAR SETTLEMENT_ACCT_NO FK
--         NUMERIC SHARD_THRESHOLD
--         NUMERIC SHARD_BUFFER
--         SMALLINT SWEEP_INTERVAL_SEC
--         VARCHAR GROUP_STATUS
--     }
--
--     WLT_ACCT {
--         BIGINT  INTERNAL_KEY PK
--         VARCHAR ACCT_NO UK
--         VARCHAR CLIENT_NO FK
--         VARCHAR ACCT_TYPE FK
--         VARCHAR CCY FK
--         VARCHAR ACCT_STATUS
--         NUMERIC ACTUAL_BAL
--         NUMERIC LEDGER_BAL
--         NUMERIC CALC_BAL "generated stored"
--         NUMERIC PREV_DAY_ACTUAL_BAL
--         NUMERIC TOTAL_RESTRAINED_AMT
--         VARCHAR RESTRAINT_PRESENT
--         VARCHAR CR_BLOCKED
--         INT     VERSION
--         VARCHAR GROUP_ID FK
--         SMALLINT SHARD_INDEX
--         VARCHAR ACCT_ROLE
--     }
--
--     WLT_ACCT_BAL {
--         BIGINT  INTERNAL_KEY PK_FK
--         DATE    TRAN_DATE PK
--         NUMERIC ACTUAL_BAL
--         NUMERIC LEDGER_BAL
--         NUMERIC CALC_BAL
--         NUMERIC PREV_ACTUAL_BAL
--     }
--
--     WLT_TRAN_DEF {
--         VARCHAR TRAN_TYPE PK
--         VARCHAR TRAN_DESC
--         VARCHAR CR_DR_MAINT_IND
--         VARCHAR REVERSAL_TRAN_TYPE
--         VARCHAR CHECK_FUND_IND
--         VARCHAR CHECK_RESTRAINT_IND
--         VARCHAR SOURCE_TYPE
--         VARCHAR CONTRA_GL_CODE
--         NUMERIC FEE_AMT
--         NUMERIC FEE_RATE
--         NUMERIC VAT_RATE
--         VARCHAR FEE_GL_CODE FK
--         VARCHAR VAT_GL_CODE FK
--     }
--
--     WLT_TRAN_HIST {
--         BIGINT  INTERNAL_KEY PK
--         BIGINT  SEQ_NO PK
--         DATE    POST_DATE PK
--         VARCHAR TRAN_TYPE FK
--         DATE    TRAN_DATE
--         DATE    EFFECT_DATE
--         DATE    VALUE_DATE
--         NUMERIC TRAN_AMT
--         VARCHAR CR_DR_MAINT_IND
--         NUMERIC PREVIOUS_BAL_AMT
--         NUMERIC ACTUAL_BAL_AMT
--         BIGINT  TFR_INTERNAL_KEY
--         VARCHAR REFERENCE
--         JSONB   METADATA
--         JSONB   CLIENT_INFO
--     }
--
--     WLT_BATCH {
--         BIGINT  TRAN_KEY PK
--         BIGINT  SEQ_NO PK
--         VARCHAR GL_CODE FK
--         VARCHAR CLIENT_NO
--         NUMERIC AMOUNT
--         VARCHAR TRAN_NATURE
--         VARCHAR CCY FK
--         DATE    POST_DATE
--         VARCHAR STATUS
--     }
--
--     WLT_RESTRAINTS {
--         BIGINT  SEQ_NO PK
--         BIGINT  INTERNAL_KEY FK
--         VARCHAR GROUP_ID FK
--         VARCHAR RESTRAINT_TYPE
--         VARCHAR RESTRAINT_PURPOSE
--         NUMERIC PLEDGED_AMT
--         DATE    START_DATE
--         DATE    END_DATE
--         VARCHAR STATUS
--     }
--
--     WLT_SWEEP_LOG {
--         BIGINT  SEQ_NO PK
--         VARCHAR GROUP_ID FK
--         VARCHAR SHARD_ACCT_NO
--         VARCHAR SETTLEMENT_ACCT_NO
--         NUMERIC SWEPT_AMOUNT
--         VARCHAR TRIGGER_TYPE
--         VARCHAR STATUS
--     }
--
--     WLT_GL_MAP {
--         VARCHAR ACCT_TYPE PK
--         VARCHAR EVENT_TYPE PK
--         VARCHAR GL_CODE FK
--         VARCHAR GL_DESC
--     }
--
--     WLT_NOSTRO_LINK {
--         VARCHAR NOSTRO_ID PK
--         BIGINT  NOS_VOS_NO FK_UK
--         VARCHAR GL_CODE FK
--         VARCHAR STATUS
--         DATE    LAST_RECON_DATE
--     }
--
--     WLT_NOSTRO_BAL {
--         VARCHAR NOSTRO_ID PK_FK
--         DATE    BAL_DATE PK
--         NUMERIC BANK_REPORTED_BAL
--         NUMERIC LEDGER_BAL
--         NUMERIC DIFF_AMT "generated stored"
--         VARCHAR RECON_STATUS
--     }
--
--     WLT_RECON_BREAK {
--         BIGINT  BREAK_ID PK
--         VARCHAR NOSTRO_ID FK
--         DATE    BAL_DATE FK
--         NUMERIC BREAK_AMT
--         VARCHAR BREAK_TYPE
--         VARCHAR STATUS
--     }
--
--     WLT_API_MESSAGE {
--         BIGINT  SEQ_NO PK
--         VARCHAR OBJECT_REF_ID UK
--         VARCHAR OBJECT_CHANNEL
--         VARCHAR OBJECT_SUBJECT
--         TEXT    OBJECT_REQUEST_DATA
--         TEXT    OBJECT_RESPONE_DATA
--         TIMESTAMPTZ OBJECT_DATE
--     }
--
--     WLT_API_TRACE {
--         BIGINT  TRACE_ID PK
--         BIGINT  API_SEQ_NO FK
--         VARCHAR TRACE_STEP
--         VARCHAR STATUS
--         INT     DURATION_MS
--         TEXT    ERROR_DETAIL
--         TIMESTAMPTZ CREATED_AT
--     }
--
--     WLT_OUTBOX {
--         BIGINT  EVENT_ID PK
--         UUID    EVENT_UUID UK
--         VARCHAR AGGREGATE_TYPE
--         VARCHAR AGGREGATE_ID
--         VARCHAR EVENT_TYPE
--         VARCHAR TOPIC
--         JSONB   PAYLOAD
--         VARCHAR STATUS
--         TIMESTAMPTZ CREATED_AT PK
--     }
--
--     WLT_WITHDRAW_TRACK {
--         BIGINT  TFR_INTERNAL_KEY PK
--         VARCHAR ACCT_NO
--         VARCHAR CLIENT_NO
--         NUMERIC AMOUNT
--         NUMERIC FEE_GROSS
--         VARCHAR EXT_PAYOUT_REF UK
--         VARCHAR STATUS
--         TIMESTAMPTZ SUBMITTED_AT
--         TIMESTAMPTZ ACK_DEADLINE
--         TIMESTAMPTZ FINAL_DEADLINE
--     }
--
--     WLT_STMT_DETAIL {
--         BIGINT  STMT_ID PK
--         BIGINT  INTERNAL_KEY FK
--         DATE    STMT_DATE
--         DATE    FROM_DATE
--         DATE    TO_DATE
--         VARCHAR FORMAT
--         VARCHAR STATUS
--     }
--
--     WLT_CLIENT_AUDIT_LOG {
--         BIGINT      AUDIT_ID PK
--         VARCHAR     CLIENT_NO FK
--         VARCHAR     TABLE_NAME
--         VARCHAR     OPERATION
--         TIMESTAMPTZ CHANGED_AT PK
--         VARCHAR     CHANGED_BY
--         VARCHAR     CHANGE_SOURCE
--         JSONB       OLD_VALUES
--         JSONB       NEW_VALUES
--         TEXT_ARR    CHANGED_FIELDS
--         VARCHAR     MAKER_ID
--         VARCHAR     CHECKER_ID
--         VARCHAR     APPROVAL_REF
--     }
-- ```


-- #############################################################################
-- #                                                                           #
-- #   SECTION 1 — EXTENSIONS & SEQUENCES                                      #
-- #                                                                           #
-- #############################################################################

-- UUID generation for WLT_OUTBOX.EVENT_UUID
-- (PG 13+ has gen_random_uuid() built-in; this is a safety net)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- TFR_INTERNAL_KEY — links legs of a single transfer.
-- Not using IDENTITY because multiple rows share one value.
CREATE SEQUENCE IF NOT EXISTS seq_tfr AS BIGINT CACHE 1000;


-- #############################################################################
-- #                                                                           #
-- #   SECTION 2 — FM TIER (Foundation Master)                                 #
-- #   Read-only from WLT's perspective                                        #
-- #                                                                           #
-- #############################################################################

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.1  FM_CURRENCY
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE FM_CURRENCY (
  CCY              VARCHAR(4)    PRIMARY KEY,
  CCY_DESC         VARCHAR(80),
  DECI_PLACES      SMALLINT      DEFAULT 2,
  DAY_BASIS        SMALLINT      DEFAULT 360,
  ROUND_TRUNC      VARCHAR(4),
  CCY_GROUP        VARCHAR(4)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.2  FM_GL_MAST — Chart of accounts (single source of truth)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE FM_GL_MAST (
  GL_CODE          VARCHAR(32)   PRIMARY KEY,
  GL_CODE_DESC     VARCHAR(120)  NOT NULL,
  GL_CODE_TYPE     VARCHAR(4),                 -- 'A'=Asset,'L'=Liab,'I'=Income,'E'=Expense
  CONTROL_GL_CODE  VARCHAR(32),                -- parent (account tree)
  BSPL_TYPE        VARCHAR(4),                 -- 'B'=Balance sheet, 'P'=P&L
  GL_TYPE          VARCHAR(4),
  TFR_IND          VARCHAR(4),
  STATUS           VARCHAR(4)    DEFAULT 'A',
  CONSTRAINT fk_gl_parent FOREIGN KEY (CONTROL_GL_CODE) REFERENCES FM_GL_MAST(GL_CODE)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.3  FM_CLIENT — Customer master
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE FM_CLIENT (
  CLIENT_NO            VARCHAR(48)   PRIMARY KEY,
  GLOBAL_ID            VARCHAR(64),                   -- CCCD/Passport number
  GLOBAL_ID_TYPE       VARCHAR(12),                   -- 'CCCD','PASSPORT'
  CLIENT_NAME          VARCHAR(200)  NOT NULL,
  CLIENT_SHORT         VARCHAR(100),
  CLIENT_TYPE          VARCHAR(12),                   -- 'IND'=individual, 'CORP'=corporate
  CLIENT_GRP           VARCHAR(48),
  ACCT_EXEC            VARCHAR(12),                   -- relationship manager
  COUNTRY_LOC          VARCHAR(8),
  COUNTRY_CITIZEN      VARCHAR(8),
  COUNTRY_RISK         VARCHAR(8),
  STATE_LOC            VARCHAR(8),
  REGISTERED_DATE      DATE,
  MAJOR_CATEGORY       VARCHAR(8),
  NON_RESIDENT_CTRL    VARCHAR(4),
  OWNERSHIP            VARCHAR(4),
  TAX_FILE_NO          VARCHAR(60),
  TAXABLE_IND          VARCHAR(4),
  STATUS               VARCHAR(4)    DEFAULT 'A',
  CONSTRAINT uk_fm_client_gid UNIQUE (GLOBAL_ID, GLOBAL_ID_TYPE)
);

CREATE INDEX idx_fmc_name ON FM_CLIENT(CLIENT_NAME);
CREATE INDEX idx_fmc_gid  ON FM_CLIENT(GLOBAL_ID);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.4  FM_CLIENT_INDVL — Individual-specific extension
-- ─────────────────────────────────────────────────────────────────────────────
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

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.5  FM_CLIENT_IDENTIFIERS — Multiple IDs per client
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE FM_CLIENT_IDENTIFIERS (
  CLIENT_NO         VARCHAR(48)   NOT NULL,
  GLOBAL_ID         VARCHAR(64)   NOT NULL,
  GLOBAL_ID_TYPE    VARCHAR(20)   NOT NULL,
  DT_OF_ISSUANCE    DATE,
  EXPIRY_DATE       DATE,
  PLACE_OF_ISSUANCE VARCHAR(120),
  IS_CURRENT        SMALLINT      DEFAULT 1,
  NATIONALITY       VARCHAR(8),
  PRIMARY KEY (CLIENT_NO, GLOBAL_ID, GLOBAL_ID_TYPE),
  CONSTRAINT fk_idf_client FOREIGN KEY (CLIENT_NO) REFERENCES FM_CLIENT(CLIENT_NO)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.6  FM_CLIENT_CONTACT — Contact info per client
--      (Referenced in ERD; DDL added here for completeness)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE FM_CLIENT_CONTACT (
  CONTACT_ID       BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  CLIENT_NO        VARCHAR(48)   NOT NULL,
  CONTACT_TYPE     VARCHAR(12)   NOT NULL,           -- 'MOBILE','EMAIL','ADDRESS','ZALO'
  CONTACT_VALUE    VARCHAR(200)  NOT NULL,           -- P1 — encrypted at rest
  IS_PRIMARY       SMALLINT      DEFAULT 0,
  IS_VERIFIED      SMALLINT      DEFAULT 0,
  VERIFIED_AT      TIMESTAMPTZ,
  STATUS           VARCHAR(4)    DEFAULT 'A',
  CREATED_AT       TIMESTAMPTZ   DEFAULT NOW(),
  UPDATED_AT       TIMESTAMPTZ   DEFAULT NOW(),
  CONSTRAINT fk_contact_client FOREIGN KEY (CLIENT_NO) REFERENCES FM_CLIENT(CLIENT_NO),
  CONSTRAINT chk_contact_type  CHECK (CONTACT_TYPE IN ('MOBILE','EMAIL','ADDRESS','ZALO','OTHER'))
);

CREATE INDEX idx_fmc_contact_client ON FM_CLIENT_CONTACT(CLIENT_NO);
CREATE INDEX idx_fmc_contact_value  ON FM_CLIENT_CONTACT(CONTACT_TYPE, CONTACT_VALUE);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.7  FM_CLIENT_BANKS — Linked bank accounts per client
--      (Referenced in ERD; DDL added here for completeness)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE FM_CLIENT_BANKS (
  LINK_ID           BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  CLIENT_NO         VARCHAR(48)   NOT NULL,
  BANK_CODE         VARCHAR(20)   NOT NULL,           -- NAPAS BIN or bank swift
  BANK_NAME         VARCHAR(120),
  ACCT_NO_ENC       BYTEA         NOT NULL,           -- P1 — encrypted (see DLD §8.3)
  ACCT_HOLDER_NAME  VARCHAR(200),
  IS_DEFAULT        SMALLINT      NOT NULL DEFAULT 0, -- customer's default payout bank
  STATUS            VARCHAR(4)    NOT NULL DEFAULT 'A',
  VERIFIED_AT       TIMESTAMPTZ,
  -- audit quintet (matches deployed convention; set by fn_set_audit_columns)
  CHANNEL           VARCHAR(20),
  CREATED_AT        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  CREATED_BY        VARCHAR(64)   NOT NULL DEFAULT 'SYSTEM',
  UPDATED_AT        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  UPDATED_BY        VARCHAR(64)   NOT NULL DEFAULT 'SYSTEM',
  CONSTRAINT fk_banks_client  FOREIGN KEY (CLIENT_NO) REFERENCES FM_CLIENT(CLIENT_NO),
  CONSTRAINT chk_cb_default   CHECK (IS_DEFAULT IN (0, 1))
);

CREATE INDEX idx_fmc_banks_client ON FM_CLIENT_BANKS(CLIENT_NO);
-- At most one default bank per client.
CREATE UNIQUE INDEX uk_cb_one_default ON FM_CLIENT_BANKS(CLIENT_NO) WHERE IS_DEFAULT = 1;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.8  FM_NOS_VOS — Nostro/Vostro master (TKĐBTT)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE FM_NOS_VOS (
  NOS_VOS_NO       BIGINT        PRIMARY KEY,
  ACCT_TYPE        VARCHAR(12),                       -- 'NOSTRO','VOSTRO','TKDBTT'
  CCY              VARCHAR(4),
  CLIENT_NO        VARCHAR(48),                       -- = our company client_no
  ACCT_DESC        VARCHAR(120),
  GL_CODE          VARCHAR(32)   NOT NULL,
  ACCT_NO          VARCHAR(80)   NOT NULL,            -- real account at partner bank
  INTERNAL_KEY     BIGINT,
  CONSTRAINT fk_nos_gl  FOREIGN KEY (GL_CODE) REFERENCES FM_GL_MAST(GL_CODE),
  CONSTRAINT fk_nos_ccy FOREIGN KEY (CCY)     REFERENCES FM_CURRENCY(CCY)
);


-- #############################################################################
-- #                                                                           #
-- #   SECTION 3 — WLT TIER (Wallet Transactional)                             #
-- #                                                                           #
-- #############################################################################

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.1  WLT_CLIENT_KYC
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_CLIENT_KYC (
  KYC_ID            BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  CLIENT_NO         VARCHAR(48)   NOT NULL,
  PHONE_NO          VARCHAR(20)   NOT NULL UNIQUE,
  EMAIL             VARCHAR(120),
  KYC_TIER          VARCHAR(4)    DEFAULT '1',
  EKYC_PROVIDER     VARCHAR(40),                       -- 'VNG','FPT','TS'
  EKYC_REF          VARCHAR(80),
  FACE_MATCH_SCORE  NUMERIC(5,3),
  LIVENESS_RESULT   VARCHAR(8),                        -- 'PASS','FAIL'
  DOC_URL           VARCHAR(400),
  STATUS            VARCHAR(4)    DEFAULT 'A',
  RISK_LEVEL        VARCHAR(4)    DEFAULT 'L',
  VERIFIED_AT       TIMESTAMPTZ,
  VERIFIED_BY       VARCHAR(40),
  CREATED_AT        TIMESTAMPTZ   DEFAULT NOW(),
  CONSTRAINT fk_kyc_client FOREIGN KEY (CLIENT_NO) REFERENCES FM_CLIENT(CLIENT_NO),
  CONSTRAINT chk_kyc_tier  CHECK (KYC_TIER IN ('0','1','2','3')),
  CONSTRAINT chk_kyc_st    CHECK (STATUS IN ('A','B','C','P'))
);

CREATE INDEX idx_kyc_client ON WLT_CLIENT_KYC(CLIENT_NO);
CREATE INDEX idx_kyc_phone  ON WLT_CLIENT_KYC(PHONE_NO);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.2  WLT_ACCT_TYPE — classifier (limit & GL mapping)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_ACCT_TYPE (
  ACCT_TYPE        VARCHAR(12)   PRIMARY KEY,
  ACCT_TYPE_DESC   VARCHAR(80)   NOT NULL,
  GL_CODE_LIAB     VARCHAR(32)   NOT NULL,
  PROD_ID          VARCHAR(16),
  DAILY_LIMIT      NUMERIC(18,2) DEFAULT 20000000,
  MONTHLY_LIMIT    NUMERIC(18,2) DEFAULT 100000000,
  INT_BEARING      VARCHAR(1)    DEFAULT 'N',
  STATUS           VARCHAR(4)    DEFAULT 'A',
  CONSTRAINT fk_at_gl FOREIGN KEY (GL_CODE_LIAB) REFERENCES FM_GL_MAST(GL_CODE)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.3  WLT_ACCT_GROUP — sub-account sharding container
--      (Y1: DDL created, application logic deferred until 1 merchant > 30 TPS)
-- ─────────────────────────────────────────────────────────────────────────────
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
  CREATED_AT           TIMESTAMPTZ   DEFAULT NOW(),
  UPDATED_AT           TIMESTAMPTZ   DEFAULT NOW(),
  CONSTRAINT fk_group_client     FOREIGN KEY (CLIENT_NO) REFERENCES FM_CLIENT(CLIENT_NO),
  -- DEFERRABLE: chicken-and-egg with WLT_ACCT (settlement acct needs group_id first)
  CONSTRAINT fk_group_settlement FOREIGN KEY (SETTLEMENT_ACCT_NO)
                                 REFERENCES WLT_ACCT(ACCT_NO) DEFERRABLE INITIALLY DEFERRED,
  CONSTRAINT chk_group_type      CHECK (GROUP_TYPE IN ('MERCHANT','AGENT','NOSTRO_HOT')),
  CONSTRAINT chk_shard_count     CHECK (SHARD_COUNT IN (8, 16, 32, 64))
);

CREATE INDEX idx_group_client ON WLT_ACCT_GROUP(CLIENT_NO);
CREATE INDEX idx_group_status ON WLT_ACCT_GROUP(GROUP_STATUS);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.4  WLT_ACCT — wallet account
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_ACCT (
  INTERNAL_KEY         BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ACCT_NO              VARCHAR(20)   NOT NULL UNIQUE,
  CLIENT_NO            VARCHAR(48)   NOT NULL,
  ACCT_TYPE            VARCHAR(12)   NOT NULL,
  CCY                  VARCHAR(4)    NOT NULL DEFAULT 'VND',
  ACCT_STATUS          VARCHAR(4)    NOT NULL DEFAULT 'A',
  ACTUAL_BAL           NUMERIC(18,2) NOT NULL DEFAULT 0,
  LEDGER_BAL           NUMERIC(18,2) NOT NULL DEFAULT 0,
  TOTAL_RESTRAINED_AMT NUMERIC(18,2) NOT NULL DEFAULT 0,
  CALC_BAL             NUMERIC(18,2) GENERATED ALWAYS AS (ACTUAL_BAL - TOTAL_RESTRAINED_AMT) STORED,
  PREV_DAY_ACTUAL_BAL  NUMERIC(18,2) DEFAULT 0,
  ACCT_OPEN_DATE       DATE          DEFAULT CURRENT_DATE,
  LAST_TRAN_DATE       TIMESTAMPTZ,
  RESTRAINT_PRESENT    VARCHAR(4)    DEFAULT 'N',
  CR_BLOCKED           VARCHAR(1)    DEFAULT 'N',
  VERSION              INTEGER       DEFAULT 0,
  -- Sub-account sharding (v1.6.3) ──────────────────────────────
  GROUP_ID             VARCHAR(20),
  SHARD_INDEX          SMALLINT,
  ACCT_ROLE            VARCHAR(12)   NOT NULL DEFAULT 'STANDALONE',
  BRANCH               VARCHAR(20),
  -- FK references ──────────────────────────────────────────────
  CONSTRAINT fk_acct_fm_client  FOREIGN KEY (CLIENT_NO) REFERENCES FM_CLIENT(CLIENT_NO),
  CONSTRAINT fk_acct_fm_ccy     FOREIGN KEY (CCY)       REFERENCES FM_CURRENCY(CCY),
  CONSTRAINT fk_acct_type       FOREIGN KEY (ACCT_TYPE) REFERENCES WLT_ACCT_TYPE(ACCT_TYPE),
  CONSTRAINT fk_acct_group      FOREIGN KEY (GROUP_ID)  REFERENCES WLT_ACCT_GROUP(GROUP_ID),
  -- Invariants ─────────────────────────────────────────────────
  CONSTRAINT chk_acct_bal        CHECK (ACTUAL_BAL >= 0),
  CONSTRAINT chk_acct_avail      CHECK (ACTUAL_BAL >= TOTAL_RESTRAINED_AMT),
  CONSTRAINT chk_acct_restrained CHECK (TOTAL_RESTRAINED_AMT >= 0),
  CONSTRAINT chk_acct_role       CHECK (ACCT_ROLE IN ('STANDALONE','SHARD','SETTLEMENT')),
  CONSTRAINT chk_shard_consistency CHECK (
    (ACCT_ROLE = 'STANDALONE' AND GROUP_ID IS NULL     AND SHARD_INDEX IS NULL) OR
    (ACCT_ROLE = 'SHARD'      AND GROUP_ID IS NOT NULL AND SHARD_INDEX IS NOT NULL) OR
    (ACCT_ROLE = 'SETTLEMENT' AND GROUP_ID IS NOT NULL AND SHARD_INDEX IS NULL)
  )
);

CREATE INDEX idx_acct_client     ON WLT_ACCT(CLIENT_NO);
CREATE INDEX idx_acct_status     ON WLT_ACCT(ACCT_STATUS, ACCT_TYPE);
CREATE INDEX idx_acct_ccy        ON WLT_ACCT(CCY);
CREATE INDEX idx_acct_group_role ON WLT_ACCT(GROUP_ID, ACCT_ROLE) WHERE GROUP_ID IS NOT NULL;
CREATE UNIQUE INDEX uk_acct_shard      ON WLT_ACCT(GROUP_ID, SHARD_INDEX) WHERE ACCT_ROLE = 'SHARD';
CREATE UNIQUE INDEX uk_acct_settlement ON WLT_ACCT(GROUP_ID) WHERE ACCT_ROLE = 'SETTLEMENT';

ALTER TABLE WLT_ACCT SET (fillfactor = 80);
ALTER TABLE WLT_ACCT SET (autovacuum_vacuum_scale_factor = 0.02);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.5  WLT_ACCT_BAL — daily balance snapshot (partitioned by month)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_ACCT_BAL (
  INTERNAL_KEY    BIGINT        NOT NULL,
  TRAN_DATE       DATE          NOT NULL,
  ACTUAL_BAL      NUMERIC(18,2) NOT NULL,
  LEDGER_BAL      NUMERIC(18,2) NOT NULL,
  CALC_BAL        NUMERIC(18,2) NOT NULL,
  PREV_ACTUAL_BAL NUMERIC(18,2),
  PREV_LEDGER_BAL NUMERIC(18,2),
  PREV_CALC_BAL   NUMERIC(18,2),
  CREATED_AT      TIMESTAMPTZ   DEFAULT NOW(),
  PRIMARY KEY (INTERNAL_KEY, TRAN_DATE),
  CONSTRAINT fk_bal_acct FOREIGN KEY (INTERNAL_KEY) REFERENCES WLT_ACCT(INTERNAL_KEY)
) PARTITION BY RANGE (TRAN_DATE);

-- Y1: create partitions manually every 6 months (defer pg_partman until DB > 100 GB)
CREATE TABLE wlt_acct_bal_2026_01 PARTITION OF WLT_ACCT_BAL FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE wlt_acct_bal_2026_02 PARTITION OF WLT_ACCT_BAL FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE wlt_acct_bal_2026_03 PARTITION OF WLT_ACCT_BAL FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE wlt_acct_bal_2026_04 PARTITION OF WLT_ACCT_BAL FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE wlt_acct_bal_2026_05 PARTITION OF WLT_ACCT_BAL FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE wlt_acct_bal_2026_06 PARTITION OF WLT_ACCT_BAL FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE wlt_acct_bal_2026_07 PARTITION OF WLT_ACCT_BAL FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE wlt_acct_bal_2026_08 PARTITION OF WLT_ACCT_BAL FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE wlt_acct_bal_2026_09 PARTITION OF WLT_ACCT_BAL FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE wlt_acct_bal_2026_10 PARTITION OF WLT_ACCT_BAL FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE wlt_acct_bal_2026_11 PARTITION OF WLT_ACCT_BAL FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE wlt_acct_bal_2026_12 PARTITION OF WLT_ACCT_BAL FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.6  WLT_TRAN_DEF — transaction type definitions (+ fee & VAT config)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_TRAN_DEF (
  TRAN_TYPE             VARCHAR(6)    PRIMARY KEY,
  TRAN_DESC             VARCHAR(120),
  CR_DR_MAINT_IND       VARCHAR(2),
  REVERSAL_TRAN_TYPE    VARCHAR(6),
  CHECK_FUND_IND        VARCHAR(1)    DEFAULT 'Y',
  CHECK_RESTRAINT_IND   VARCHAR(1)    DEFAULT 'Y',
  SOURCE_TYPE           VARCHAR(8),
  CONTRA_GL_CODE        VARCHAR(32),
  MIN_TRAN_AMT          NUMERIC(18,2) DEFAULT 1000,
  MAX_TRAN_AMT          NUMERIC(18,2) DEFAULT 100000000,
  MAX_FUTURE_DATE_DAYS  SMALLINT      DEFAULT 0,
  AUTO_APPROVAL         VARCHAR(1)    DEFAULT 'Y',
  NARRATIVE             VARCHAR(160),
  STATUS                VARCHAR(1)    DEFAULT 'A',
  -- Fee & VAT config (v1.3) ──────────────────────────────────
  FEE_TYPE              VARCHAR(8)    DEFAULT 'NONE',
  FEE_AMT               NUMERIC(18,2) DEFAULT 0,
  FEE_RATE              NUMERIC(10,6) DEFAULT 0,
  FEE_MIN               NUMERIC(18,2) DEFAULT 0,
  FEE_MAX               NUMERIC(18,2) DEFAULT 0,
  VAT_RATE              NUMERIC(6,4)  DEFAULT 0.10,
  FEE_GL_CODE           VARCHAR(32),
  VAT_GL_CODE           VARCHAR(32),
  FEE_TRAN_TYPE         VARCHAR(6),
  CONSTRAINT chk_fee_type  CHECK (FEE_TYPE IN ('NONE','FIXED','PERCENT')),
  CONSTRAINT fk_def_fee_gl FOREIGN KEY (FEE_GL_CODE) REFERENCES FM_GL_MAST(GL_CODE),
  CONSTRAINT fk_def_vat_gl FOREIGN KEY (VAT_GL_CODE) REFERENCES FM_GL_MAST(GL_CODE)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.7  WLT_TRAN_HIST — transaction history (partitioned: month × hash32)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_TRAN_HIST (
  INTERNAL_KEY        BIGINT        NOT NULL,
  SEQ_NO              BIGINT        GENERATED ALWAYS AS IDENTITY,
  TRAN_TYPE           VARCHAR(6)    NOT NULL,
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
  SOURCE_MODULE       VARCHAR(8)    DEFAULT 'WLT',
  TRAN_DESC           VARCHAR(200),
  TERMINAL_ID         VARCHAR(40),
  OFFICER_ID          VARCHAR(40),
  -- Sharding denorm (v1.6.3) ──────────────────────────────────
  GROUP_ID            VARCHAR(20),
  SHARD_INDEX         SMALLINT,
  -- Open metadata bag (v1.6.6) ────────────────────────────────
  METADATA            JSONB,
  -- Client snapshot at posting time (v1.6.6) ──────────────────
  CLIENT_INFO         JSONB,
  TIME_STAMP          TIMESTAMPTZ   DEFAULT NOW(),
  -- PK must include partition key (POST_DATE) — PG constraint
  CONSTRAINT pk_hist PRIMARY KEY (INTERNAL_KEY, SEQ_NO, POST_DATE)
) PARTITION BY RANGE (POST_DATE);

-- Level 1: range by month, sub-partitioned by HASH(INTERNAL_KEY) × 32
-- Y1: create 12 months manually; add 6 months ahead every June/December
CREATE TABLE wlt_tran_hist_2026_01 PARTITION OF WLT_TRAN_HIST
  FOR VALUES FROM ('2026-01-01') TO ('2026-02-01')
  PARTITION BY HASH (INTERNAL_KEY);
CREATE TABLE wlt_tran_hist_2026_02 PARTITION OF WLT_TRAN_HIST
  FOR VALUES FROM ('2026-02-01') TO ('2026-03-01')
  PARTITION BY HASH (INTERNAL_KEY);
CREATE TABLE wlt_tran_hist_2026_03 PARTITION OF WLT_TRAN_HIST
  FOR VALUES FROM ('2026-03-01') TO ('2026-04-01')
  PARTITION BY HASH (INTERNAL_KEY);
CREATE TABLE wlt_tran_hist_2026_04 PARTITION OF WLT_TRAN_HIST
  FOR VALUES FROM ('2026-04-01') TO ('2026-05-01')
  PARTITION BY HASH (INTERNAL_KEY);
CREATE TABLE wlt_tran_hist_2026_05 PARTITION OF WLT_TRAN_HIST
  FOR VALUES FROM ('2026-05-01') TO ('2026-06-01')
  PARTITION BY HASH (INTERNAL_KEY);
CREATE TABLE wlt_tran_hist_2026_06 PARTITION OF WLT_TRAN_HIST
  FOR VALUES FROM ('2026-06-01') TO ('2026-07-01')
  PARTITION BY HASH (INTERNAL_KEY);
CREATE TABLE wlt_tran_hist_2026_07 PARTITION OF WLT_TRAN_HIST
  FOR VALUES FROM ('2026-07-01') TO ('2026-08-01')
  PARTITION BY HASH (INTERNAL_KEY);
CREATE TABLE wlt_tran_hist_2026_08 PARTITION OF WLT_TRAN_HIST
  FOR VALUES FROM ('2026-08-01') TO ('2026-09-01')
  PARTITION BY HASH (INTERNAL_KEY);
CREATE TABLE wlt_tran_hist_2026_09 PARTITION OF WLT_TRAN_HIST
  FOR VALUES FROM ('2026-09-01') TO ('2026-10-01')
  PARTITION BY HASH (INTERNAL_KEY);
CREATE TABLE wlt_tran_hist_2026_10 PARTITION OF WLT_TRAN_HIST
  FOR VALUES FROM ('2026-10-01') TO ('2026-11-01')
  PARTITION BY HASH (INTERNAL_KEY);
CREATE TABLE wlt_tran_hist_2026_11 PARTITION OF WLT_TRAN_HIST
  FOR VALUES FROM ('2026-11-01') TO ('2026-12-01')
  PARTITION BY HASH (INTERNAL_KEY);
CREATE TABLE wlt_tran_hist_2026_12 PARTITION OF WLT_TRAN_HIST
  FOR VALUES FROM ('2026-12-01') TO ('2027-01-01')
  PARTITION BY HASH (INTERNAL_KEY);

-- Sub-partitions: each monthly partition → 32 hash buckets
-- Generating for 2026_01 as example; repeat for each month (or script via DO block §6)
CREATE TABLE wlt_tran_hist_2026_01_h00 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 0);
CREATE TABLE wlt_tran_hist_2026_01_h01 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 1);
CREATE TABLE wlt_tran_hist_2026_01_h02 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 2);
CREATE TABLE wlt_tran_hist_2026_01_h03 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 3);
CREATE TABLE wlt_tran_hist_2026_01_h04 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 4);
CREATE TABLE wlt_tran_hist_2026_01_h05 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 5);
CREATE TABLE wlt_tran_hist_2026_01_h06 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 6);
CREATE TABLE wlt_tran_hist_2026_01_h07 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 7);
CREATE TABLE wlt_tran_hist_2026_01_h08 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 8);
CREATE TABLE wlt_tran_hist_2026_01_h09 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 9);
CREATE TABLE wlt_tran_hist_2026_01_h10 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 10);
CREATE TABLE wlt_tran_hist_2026_01_h11 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 11);
CREATE TABLE wlt_tran_hist_2026_01_h12 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 12);
CREATE TABLE wlt_tran_hist_2026_01_h13 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 13);
CREATE TABLE wlt_tran_hist_2026_01_h14 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 14);
CREATE TABLE wlt_tran_hist_2026_01_h15 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 15);
CREATE TABLE wlt_tran_hist_2026_01_h16 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 16);
CREATE TABLE wlt_tran_hist_2026_01_h17 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 17);
CREATE TABLE wlt_tran_hist_2026_01_h18 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 18);
CREATE TABLE wlt_tran_hist_2026_01_h19 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 19);
CREATE TABLE wlt_tran_hist_2026_01_h20 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 20);
CREATE TABLE wlt_tran_hist_2026_01_h21 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 21);
CREATE TABLE wlt_tran_hist_2026_01_h22 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 22);
CREATE TABLE wlt_tran_hist_2026_01_h23 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 23);
CREATE TABLE wlt_tran_hist_2026_01_h24 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 24);
CREATE TABLE wlt_tran_hist_2026_01_h25 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 25);
CREATE TABLE wlt_tran_hist_2026_01_h26 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 26);
CREATE TABLE wlt_tran_hist_2026_01_h27 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 27);
CREATE TABLE wlt_tran_hist_2026_01_h28 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 28);
CREATE TABLE wlt_tran_hist_2026_01_h29 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 29);
CREATE TABLE wlt_tran_hist_2026_01_h30 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 30);
CREATE TABLE wlt_tran_hist_2026_01_h31 PARTITION OF wlt_tran_hist_2026_01 FOR VALUES WITH (MODULUS 32, REMAINDER 31);

-- Indexes on parent — PG auto-propagates to all partitions
CREATE INDEX idx_hist_acct_date  ON WLT_TRAN_HIST(INTERNAL_KEY, POST_DATE DESC);
CREATE INDEX idx_hist_tfr        ON WLT_TRAN_HIST(TFR_INTERNAL_KEY, TFR_SEQ_NO);
CREATE INDEX idx_hist_ref        ON WLT_TRAN_HIST(REFERENCE);
CREATE INDEX idx_hist_group_date ON WLT_TRAN_HIST(GROUP_ID, POST_DATE DESC) WHERE GROUP_ID IS NOT NULL;

-- JSONB compression
ALTER TABLE WLT_TRAN_HIST ALTER COLUMN METADATA    SET STORAGE EXTENDED;
ALTER TABLE WLT_TRAN_HIST ALTER COLUMN METADATA    SET COMPRESSION lz4;
ALTER TABLE WLT_TRAN_HIST ALTER COLUMN CLIENT_INFO SET STORAGE EXTENDED;
ALTER TABLE WLT_TRAN_HIST ALTER COLUMN CLIENT_INFO SET COMPRESSION lz4;

ALTER TABLE WLT_TRAN_HIST SET (autovacuum_vacuum_insert_scale_factor = 0.01);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.8  WLT_BATCH — GL feed (FK to FM_GL_MAST + FM_CURRENCY)
-- ─────────────────────────────────────────────────────────────────────────────
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
  SOURCE_MODULE     VARCHAR(8)    DEFAULT 'WLT',
  STATUS            VARCHAR(4)    DEFAULT 'P',
  TIME_STAMP        TIMESTAMPTZ   DEFAULT NOW(),
  PRIMARY KEY (TRAN_KEY, SEQ_NO),
  CONSTRAINT fk_batch_gl  FOREIGN KEY (GL_CODE) REFERENCES FM_GL_MAST(GL_CODE),
  CONSTRAINT fk_batch_ccy FOREIGN KEY (CCY)     REFERENCES FM_CURRENCY(CCY),
  CONSTRAINT chk_batch_nat CHECK (TRAN_NATURE IN ('DR','CR'))
);

CREATE INDEX idx_batch_gl_date ON WLT_BATCH(GL_CODE, POST_DATE);
CREATE INDEX idx_batch_ref     ON WLT_BATCH(REFERENCE);
CREATE INDEX idx_batch_acct    ON WLT_BATCH(ACCT_INTERNAL_KEY, POST_DATE);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.9  WLT_RESTRAINTS — legal/compliance hold (acct-level or group-level)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_RESTRAINTS (
  SEQ_NO            BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  INTERNAL_KEY      BIGINT,
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
  CONSTRAINT fk_rstr_acct   FOREIGN KEY (INTERNAL_KEY) REFERENCES WLT_ACCT(INTERNAL_KEY),
  CONSTRAINT fk_rstr_group  FOREIGN KEY (GROUP_ID)     REFERENCES WLT_ACCT_GROUP(GROUP_ID),
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

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.10  WLT_SWEEP_LOG — audit trail for sweep operations
--       (Y1: DDL created, logic deferred until sharding is activated)
-- ─────────────────────────────────────────────────────────────────────────────
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
  CONSTRAINT fk_sweep_group    FOREIGN KEY (GROUP_ID) REFERENCES WLT_ACCT_GROUP(GROUP_ID),
  CONSTRAINT chk_sweep_trigger CHECK (TRIGGER_TYPE IN ('PERIODIC','THRESHOLD','URGENT','EOD')),
  CONSTRAINT chk_sweep_status  CHECK (STATUS IN ('SUCCESS','CONFLICT','SKIPPED','FAILED'))
);

CREATE INDEX idx_sweep_group_time ON WLT_SWEEP_LOG(GROUP_ID, CREATED_AT DESC);
CREATE INDEX idx_sweep_shard_time ON WLT_SWEEP_LOG(SHARD_ACCT_NO, CREATED_AT DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.11  WLT_GL_MAP — mapping wallet event → FM GL code
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_GL_MAP (
  ACCT_TYPE     VARCHAR(12)  NOT NULL,
  EVENT_TYPE    VARCHAR(16)  NOT NULL,
  GL_CODE       VARCHAR(32)  NOT NULL,
  GL_DESC       VARCHAR(120),
  PRIMARY KEY (ACCT_TYPE, EVENT_TYPE),
  CONSTRAINT fk_glmap_gl FOREIGN KEY (GL_CODE) REFERENCES FM_GL_MAST(GL_CODE)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.12  WLT_NOSTRO_LINK + WLT_NOSTRO_BAL — nostro linkage & daily balance
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_NOSTRO_LINK (
  NOSTRO_ID        VARCHAR(16)   PRIMARY KEY,
  NOS_VOS_NO       BIGINT        NOT NULL UNIQUE,
  GL_CODE          VARCHAR(32)   NOT NULL,
  PURPOSE          VARCHAR(16)   DEFAULT 'TKDBTT',
  REG_NHNN_CODE    VARCHAR(32),
  STATUS           VARCHAR(4)    DEFAULT 'A',
  LAST_RECON_DATE  DATE,
  LAST_RECON_BAL   NUMERIC(18,2),
  CONSTRAINT fk_nl_fm FOREIGN KEY (NOS_VOS_NO) REFERENCES FM_NOS_VOS(NOS_VOS_NO),
  CONSTRAINT fk_nl_gl FOREIGN KEY (GL_CODE)    REFERENCES FM_GL_MAST(GL_CODE)
);

CREATE TABLE WLT_NOSTRO_BAL (
  NOSTRO_ID            VARCHAR(16)   NOT NULL,
  BAL_DATE             DATE          NOT NULL,
  BANK_REPORTED_BAL    NUMERIC(18,2),
  LEDGER_BAL           NUMERIC(18,2),
  DIFF_AMT             NUMERIC(18,2) GENERATED ALWAYS AS (BANK_REPORTED_BAL - LEDGER_BAL) STORED,
  RECON_STATUS         VARCHAR(8)    DEFAULT 'OPEN',
  PRIMARY KEY (NOSTRO_ID, BAL_DATE),
  CONSTRAINT fk_nb_link FOREIGN KEY (NOSTRO_ID) REFERENCES WLT_NOSTRO_LINK(NOSTRO_ID)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.13  WLT_RECON_BREAK — reconciliation breaks
--       (Referenced in ERD; DDL added here for completeness)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_RECON_BREAK (
  BREAK_ID          BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  NOSTRO_ID         VARCHAR(16)   NOT NULL,
  BAL_DATE          DATE          NOT NULL,
  BREAK_AMT         NUMERIC(18,2) NOT NULL,
  BREAK_TYPE        VARCHAR(16)   NOT NULL,            -- 'LEDGER_OVER','BANK_OVER','TIMING','UNKNOWN'
  DESCRIPTION       VARCHAR(500),
  RESOLUTION_NOTE   VARCHAR(500),
  STATUS            VARCHAR(8)    NOT NULL DEFAULT 'OPEN',  -- 'OPEN','INVESTIGATING','RESOLVED','ESCALATED'
  ASSIGNED_TO       VARCHAR(40),
  CREATED_AT        TIMESTAMPTZ   DEFAULT NOW(),
  RESOLVED_AT       TIMESTAMPTZ,
  CONSTRAINT fk_break_nostro FOREIGN KEY (NOSTRO_ID, BAL_DATE) REFERENCES WLT_NOSTRO_BAL(NOSTRO_ID, BAL_DATE),
  CONSTRAINT chk_break_type   CHECK (BREAK_TYPE IN ('LEDGER_OVER','BANK_OVER','TIMING','UNKNOWN')),
  CONSTRAINT chk_break_status CHECK (STATUS IN ('OPEN','INVESTIGATING','RESOLVED','ESCALATED'))
);

CREATE INDEX idx_break_nostro_date ON WLT_RECON_BREAK(NOSTRO_ID, BAL_DATE);
CREATE INDEX idx_break_status      ON WLT_RECON_BREAK(STATUS) WHERE STATUS != 'RESOLVED';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.14  WLT_API_MESSAGE — idempotency log
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_API_MESSAGE (
  SEQ_NO              BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  OBJECT_REF_ID       VARCHAR(64)   NOT NULL UNIQUE,
  OBJECT_CHANNEL      VARCHAR(40),
  OBJECT_SUBJECT      VARCHAR(40),
  OBJECT_USER         VARCHAR(64),
  OBJECT_REQUEST_DATA TEXT,
  OBJECT_RESPONE_DATA TEXT,
  HTTP_STATUS         SMALLINT,
  PROCESS_STATUS      VARCHAR(8),
  OBJECT_DATE         TIMESTAMPTZ   DEFAULT NOW(),
  PROCESSED_AT        TIMESTAMPTZ
);

ALTER TABLE WLT_API_MESSAGE ALTER COLUMN OBJECT_REQUEST_DATA SET COMPRESSION lz4;
ALTER TABLE WLT_API_MESSAGE ALTER COLUMN OBJECT_RESPONE_DATA SET COMPRESSION lz4;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.15  WLT_API_TRACE — API execution trace (per-step telemetry)
--       (Referenced in ERD & HLD §7.3; DDL added here for completeness)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_API_TRACE (
  TRACE_ID          BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  API_SEQ_NO        BIGINT        NOT NULL,             -- → WLT_API_MESSAGE.SEQ_NO
  TRACE_STEP        VARCHAR(40)   NOT NULL,             -- 'VALIDATE','LOCK','POST','FEE','OUTBOX','COMMIT'
  STATUS            VARCHAR(8)    NOT NULL,             -- 'OK','ERROR','TIMEOUT'
  DURATION_MS       INTEGER,
  ERROR_DETAIL      TEXT,
  SP_NAME           VARCHAR(60),                        -- e.g. 'post_transfer'
  CREATED_AT        TIMESTAMPTZ   DEFAULT NOW(),
  CONSTRAINT fk_trace_api FOREIGN KEY (API_SEQ_NO) REFERENCES WLT_API_MESSAGE(SEQ_NO),
  CONSTRAINT chk_trace_status CHECK (STATUS IN ('OK','ERROR','TIMEOUT'))
);

CREATE INDEX idx_trace_api     ON WLT_API_TRACE(API_SEQ_NO);
CREATE INDEX idx_trace_step    ON WLT_API_TRACE(TRACE_STEP, CREATED_AT DESC);
CREATE INDEX idx_trace_errors  ON WLT_API_TRACE(CREATED_AT DESC) WHERE STATUS != 'OK';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.16  WLT_OUTBOX — transactional outbox (partitioned by month)
-- ─────────────────────────────────────────────────────────────────────────────
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
  -- Relay state (updated by relay worker, NOT by posting SP)
  STATUS              VARCHAR(8)    NOT NULL DEFAULT 'PENDING',
  ATTEMPTS            SMALLINT      NOT NULL DEFAULT 0,
  LAST_ATTEMPT_AT     TIMESTAMPTZ,
  LAST_ERROR          VARCHAR(500),
  SENT_AT             TIMESTAMPTZ,
  KAFKA_OFFSET        BIGINT,
  KAFKA_PARTITION     SMALLINT,
  PRIMARY KEY (EVENT_ID, CREATED_AT),
  CONSTRAINT uk_outbox_uuid   UNIQUE (EVENT_UUID, CREATED_AT),
  CONSTRAINT chk_outbox_status CHECK (STATUS IN ('PENDING','SENT','FAILED','DEAD'))
) PARTITION BY RANGE (CREATED_AT);

-- Y1: create 12 monthly partitions manually
CREATE TABLE wlt_outbox_2026_01 PARTITION OF WLT_OUTBOX FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE wlt_outbox_2026_02 PARTITION OF WLT_OUTBOX FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE wlt_outbox_2026_03 PARTITION OF WLT_OUTBOX FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE wlt_outbox_2026_04 PARTITION OF WLT_OUTBOX FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE wlt_outbox_2026_05 PARTITION OF WLT_OUTBOX FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE wlt_outbox_2026_06 PARTITION OF WLT_OUTBOX FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE wlt_outbox_2026_07 PARTITION OF WLT_OUTBOX FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE wlt_outbox_2026_08 PARTITION OF WLT_OUTBOX FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE wlt_outbox_2026_09 PARTITION OF WLT_OUTBOX FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE wlt_outbox_2026_10 PARTITION OF WLT_OUTBOX FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE wlt_outbox_2026_11 PARTITION OF WLT_OUTBOX FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE wlt_outbox_2026_12 PARTITION OF WLT_OUTBOX FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

CREATE INDEX idx_outbox_pending ON WLT_OUTBOX(EVENT_ID) WHERE STATUS = 'PENDING';
CREATE INDEX idx_outbox_agg     ON WLT_OUTBOX(AGGREGATE_TYPE, AGGREGATE_ID);
CREATE INDEX idx_outbox_dead    ON WLT_OUTBOX(CREATED_AT) WHERE STATUS IN ('FAILED','DEAD');

ALTER TABLE WLT_OUTBOX ALTER COLUMN PAYLOAD SET STORAGE EXTENDED;
ALTER TABLE WLT_OUTBOX ALTER COLUMN PAYLOAD SET COMPRESSION lz4;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.17  WLT_WITHDRAW_TRACK — withdraw disbursement state machine
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_WITHDRAW_TRACK (
  TFR_INTERNAL_KEY    BIGINT        PRIMARY KEY,
  ACCT_NO             VARCHAR(20)   NOT NULL,
  CLIENT_NO           VARCHAR(48)   NOT NULL,
  AMOUNT              NUMERIC(18,2) NOT NULL,
  FEE_GROSS           NUMERIC(18,2) NOT NULL DEFAULT 0,
  CCY                 VARCHAR(4)    NOT NULL DEFAULT 'VND',
  EXT_PAYOUT_REF      VARCHAR(64)   NOT NULL UNIQUE,
  BENEFICIARY_BANK    VARCHAR(20)   NOT NULL,
  BENEFICIARY_ACCT_ENC BYTEA        NOT NULL,          -- encrypted P1 (see DLD §8.3)
  -- State machine ─────────────────────────────────────
  STATUS              VARCHAR(12)   NOT NULL DEFAULT 'SUBMITTED',
  TREASURY_BATCH_ID   VARCHAR(64),
  NAPAS_REF           VARCHAR(64),
  TREASURY_ACK_AT     TIMESTAMPTZ,
  TREASURY_FINAL_AT   TIMESTAMPTZ,
  REVERSED_AT         TIMESTAMPTZ,
  REVERSAL_TFR_KEY    BIGINT,
  -- Failure ───────────────────────────────────────────
  FAIL_CODE           VARCHAR(40),
  FAIL_REASON         VARCHAR(500),
  -- SLA tracking ──────────────────────────────────────
  SUBMITTED_AT        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  ACK_DEADLINE        TIMESTAMPTZ   NOT NULL DEFAULT (NOW() + INTERVAL '60 seconds'),
  FINAL_DEADLINE      TIMESTAMPTZ   NOT NULL DEFAULT (NOW() + INTERVAL '24 hours'),
  -- Optimistic concurrency ────────────────────────────
  VERSION             INTEGER       NOT NULL DEFAULT 0,
  CONSTRAINT chk_wd_status CHECK (STATUS IN ('SUBMITTED','ACKED','DISBURSING','COMPLETED','FAILED','REVERSED'))
);

CREATE INDEX idx_wd_status        ON WLT_WITHDRAW_TRACK(STATUS)         WHERE STATUS IN ('SUBMITTED','ACKED','DISBURSING');
CREATE INDEX idx_wd_ack_overdue   ON WLT_WITHDRAW_TRACK(ACK_DEADLINE)   WHERE STATUS = 'SUBMITTED';
CREATE INDEX idx_wd_final_overdue ON WLT_WITHDRAW_TRACK(FINAL_DEADLINE) WHERE STATUS IN ('ACKED','DISBURSING');
CREATE INDEX idx_wd_acct          ON WLT_WITHDRAW_TRACK(ACCT_NO, SUBMITTED_AT DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.18  WLT_STMT_DETAIL — customer statement detail
--       (Referenced in ERD; DDL added here for completeness)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_STMT_DETAIL (
  STMT_ID           BIGINT        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  INTERNAL_KEY      BIGINT        NOT NULL,             -- → WLT_ACCT
  STMT_DATE         DATE          NOT NULL,             -- statement generation date
  FROM_DATE         DATE          NOT NULL,             -- period start
  TO_DATE           DATE          NOT NULL,             -- period end
  OPENING_BAL       NUMERIC(18,2) NOT NULL,
  CLOSING_BAL       NUMERIC(18,2) NOT NULL,
  TOTAL_DR          NUMERIC(18,2) NOT NULL DEFAULT 0,
  TOTAL_CR          NUMERIC(18,2) NOT NULL DEFAULT 0,
  TRAN_COUNT        INTEGER       NOT NULL DEFAULT 0,
  FORMAT            VARCHAR(8)    DEFAULT 'PDF',       -- 'PDF','CSV','JSON'
  FILE_URL          VARCHAR(400),
  STATUS            VARCHAR(4)    DEFAULT 'G',         -- 'G'=generated,'S'=sent,'F'=failed
  CREATED_AT        TIMESTAMPTZ   DEFAULT NOW(),
  CONSTRAINT fk_stmt_acct FOREIGN KEY (INTERNAL_KEY) REFERENCES WLT_ACCT(INTERNAL_KEY),
  CONSTRAINT chk_stmt_fmt    CHECK (FORMAT IN ('PDF','CSV','JSON')),
  CONSTRAINT chk_stmt_status CHECK (STATUS IN ('G','S','F')),
  CONSTRAINT chk_stmt_dates  CHECK (TO_DATE >= FROM_DATE)
);

CREATE INDEX idx_stmt_acct_date ON WLT_STMT_DETAIL(INTERNAL_KEY, STMT_DATE DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.19  WLT_CLIENT_AUDIT_LOG — client change-data audit (partitioned by month)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE WLT_CLIENT_AUDIT_LOG (
  AUDIT_ID         BIGINT       GENERATED ALWAYS AS IDENTITY,
  CLIENT_NO        VARCHAR(48)  NOT NULL,
  TABLE_NAME       VARCHAR(40)  NOT NULL,
  ROW_PK           JSONB        NOT NULL,
  OPERATION        VARCHAR(8)   NOT NULL,
  CHANGED_AT       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  -- WHO
  CHANGED_BY       VARCHAR(64)  NOT NULL,
  CHANGE_SOURCE    VARCHAR(16)  NOT NULL,
  CHANGE_REASON    VARCHAR(500),
  -- WHAT
  OLD_VALUES       JSONB,
  NEW_VALUES       JSONB,
  CHANGED_FIELDS   TEXT[]       NOT NULL,
  -- WHERE FROM
  REQUEST_ID       VARCHAR(64),
  IP_ADDRESS       INET,
  USER_AGENT       VARCHAR(500),
  -- Approval chain (maker-checker)
  MAKER_ID         VARCHAR(64),
  CHECKER_ID       VARCHAR(64),
  APPROVAL_REF     VARCHAR(64),
  PRIMARY KEY (AUDIT_ID, CHANGED_AT),
  CONSTRAINT chk_audit_op  CHECK (OPERATION IN ('INSERT','UPDATE','DELETE')),
  CONSTRAINT chk_audit_src CHECK (CHANGE_SOURCE IN ('OPS_UI','API','EKYC','SYS_BATCH','COMPLIANCE','SP_BACKFILL'))
) PARTITION BY RANGE (CHANGED_AT);

-- Y1: create 12 monthly partitions manually
CREATE TABLE wlt_client_audit_log_2026_01 PARTITION OF WLT_CLIENT_AUDIT_LOG FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE wlt_client_audit_log_2026_02 PARTITION OF WLT_CLIENT_AUDIT_LOG FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE wlt_client_audit_log_2026_03 PARTITION OF WLT_CLIENT_AUDIT_LOG FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE wlt_client_audit_log_2026_04 PARTITION OF WLT_CLIENT_AUDIT_LOG FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE wlt_client_audit_log_2026_05 PARTITION OF WLT_CLIENT_AUDIT_LOG FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE wlt_client_audit_log_2026_06 PARTITION OF WLT_CLIENT_AUDIT_LOG FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE wlt_client_audit_log_2026_07 PARTITION OF WLT_CLIENT_AUDIT_LOG FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE wlt_client_audit_log_2026_08 PARTITION OF WLT_CLIENT_AUDIT_LOG FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE wlt_client_audit_log_2026_09 PARTITION OF WLT_CLIENT_AUDIT_LOG FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE wlt_client_audit_log_2026_10 PARTITION OF WLT_CLIENT_AUDIT_LOG FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE wlt_client_audit_log_2026_11 PARTITION OF WLT_CLIENT_AUDIT_LOG FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE wlt_client_audit_log_2026_12 PARTITION OF WLT_CLIENT_AUDIT_LOG FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

CREATE INDEX idx_caudit_client_time    ON WLT_CLIENT_AUDIT_LOG(CLIENT_NO, CHANGED_AT DESC);
CREATE INDEX idx_caudit_table_time     ON WLT_CLIENT_AUDIT_LOG(TABLE_NAME, CHANGED_AT DESC);
CREATE INDEX idx_caudit_changed_fields ON WLT_CLIENT_AUDIT_LOG USING GIN (CHANGED_FIELDS);
CREATE INDEX idx_caudit_request        ON WLT_CLIENT_AUDIT_LOG(REQUEST_ID) WHERE REQUEST_ID IS NOT NULL;
CREATE INDEX idx_caudit_old_jsonb      ON WLT_CLIENT_AUDIT_LOG USING GIN (OLD_VALUES jsonb_path_ops);
CREATE INDEX idx_caudit_new_jsonb      ON WLT_CLIENT_AUDIT_LOG USING GIN (NEW_VALUES jsonb_path_ops);

ALTER TABLE WLT_CLIENT_AUDIT_LOG ALTER COLUMN OLD_VALUES SET STORAGE EXTENDED;
ALTER TABLE WLT_CLIENT_AUDIT_LOG ALTER COLUMN OLD_VALUES SET COMPRESSION lz4;
ALTER TABLE WLT_CLIENT_AUDIT_LOG ALTER COLUMN NEW_VALUES SET STORAGE EXTENDED;
ALTER TABLE WLT_CLIENT_AUDIT_LOG ALTER COLUMN NEW_VALUES SET COMPRESSION lz4;


-- #############################################################################
-- #                                                                           #
-- #   SECTION 4 — VIEWS                                                       #
-- #                                                                           #
-- #############################################################################

-- ─────────────────────────────────────────────────────────────────────────────
-- 4.1  v_wlt_group_balance — aggregate balance across all shards + settlement
-- ─────────────────────────────────────────────────────────────────────────────
CREATE VIEW v_wlt_group_balance AS
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
JOIN WLT_ACCT s ON s.GROUP_ID = g.GROUP_ID AND s.ACCT_ROLE = 'SETTLEMENT'
LEFT JOIN WLT_ACCT sh ON sh.GROUP_ID = g.GROUP_ID AND sh.ACCT_ROLE = 'SHARD'
GROUP BY g.GROUP_ID, g.CLIENT_NO, g.GROUP_TYPE,
         s.ACTUAL_BAL, s.TOTAL_RESTRAINED_AMT, s.LAST_TRAN_DATE;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4.2  v_wlt_active_restraints_effective — merged acct-level + group-level
-- ─────────────────────────────────────────────────────────────────────────────
CREATE VIEW v_wlt_active_restraints_effective AS
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
  AND CURRENT_DATE BETWEEN r.START_DATE AND COALESCE(r.END_DATE, '9999-12-31');


-- #############################################################################
-- #                                                                           #
-- #   SECTION 5 — TRIGGERS & FUNCTIONS                                        #
-- #                                                                           #
-- #############################################################################

-- ─────────────────────────────────────────────────────────────────────────────
-- 5.1  fn_audit_client_change — generic trigger for client-info audit
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_audit_client_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_old   JSONB;
  v_new   JSONB;
  v_diff  TEXT[];
  v_client_no VARCHAR(48);
  v_pk    JSONB;
  v_actor VARCHAR(64);
  v_src   VARCHAR(16);
BEGIN
  -- Resolve actor + source from session GUCs (set by app via SET LOCAL audit.*)
  v_actor := COALESCE(current_setting('audit.actor',  TRUE), session_user);
  v_src   := COALESCE(current_setting('audit.source', TRUE), 'SP_BACKFILL');

  -- Build OLD/NEW JSONB
  IF TG_OP = 'INSERT' THEN
    v_old := NULL;
    v_new := to_jsonb(NEW);
    v_diff := ARRAY(SELECT jsonb_object_keys(v_new));
    v_client_no := NEW.CLIENT_NO;
  ELSIF TG_OP = 'UPDATE' THEN
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
    -- True field-level diff
    v_diff := ARRAY(
      SELECT k FROM jsonb_object_keys(v_new) k
       WHERE v_old->k IS DISTINCT FROM v_new->k
    );
    IF cardinality(v_diff) = 0 THEN
      RETURN NEW;  -- no-op UPDATE — skip audit insert
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

-- ─────────────────────────────────────────────────────────────────────────────
-- 5.2  Attach triggers — WLT-side (wallet team owns)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TRIGGER trg_audit_wlt_kyc
  AFTER INSERT OR UPDATE OR DELETE ON WLT_CLIENT_KYC
  FOR EACH ROW EXECUTE FUNCTION fn_audit_client_change();

-- FM-side triggers (install after coordination with FM data team):
-- CREATE TRIGGER trg_audit_fm_client       AFTER INSERT OR UPDATE OR DELETE ON FM_CLIENT          FOR EACH ROW EXECUTE FUNCTION fn_audit_client_change();
-- CREATE TRIGGER trg_audit_fm_client_indvl AFTER INSERT OR UPDATE OR DELETE ON FM_CLIENT_INDVL    FOR EACH ROW EXECUTE FUNCTION fn_audit_client_change();
-- CREATE TRIGGER trg_audit_fm_client_id    AFTER INSERT OR UPDATE OR DELETE ON FM_CLIENT_IDENTIFIERS FOR EACH ROW EXECUTE FUNCTION fn_audit_client_change();
-- CREATE TRIGGER trg_audit_fm_client_ct    AFTER INSERT OR UPDATE OR DELETE ON FM_CLIENT_CONTACT  FOR EACH ROW EXECUTE FUNCTION fn_audit_client_change();
-- CREATE TRIGGER trg_audit_fm_client_bk    AFTER INSERT OR UPDATE OR DELETE ON FM_CLIENT_BANKS    FOR EACH ROW EXECUTE FUNCTION fn_audit_client_change();

-- ─────────────────────────────────────────────────────────────────────────────
-- 5.3  Lock down audit table — only the SECURITY DEFINER trigger can INSERT
-- ─────────────────────────────────────────────────────────────────────────────
-- Uncomment after creating the DB roles (see DLD §8.3):
-- REVOKE INSERT, UPDATE, DELETE ON WLT_CLIENT_AUDIT_LOG FROM wallet_app, wallet_pii_ro;
-- GRANT  SELECT ON WLT_CLIENT_AUDIT_LOG TO wallet_pii_ro;


-- #############################################################################
-- #                                                                           #
-- #   SECTION 6 — HELPER: Auto-generate hash sub-partitions for WLT_TRAN_HIST #
-- #   Run once per month-partition to create h00..h31                          #
-- #                                                                           #
-- #############################################################################

CREATE OR REPLACE FUNCTION fn_create_tran_hist_hash_partitions(
  p_parent_name TEXT   -- e.g. 'wlt_tran_hist_2026_02'
) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
  i INT;
  v_sql TEXT;
BEGIN
  FOR i IN 0..31 LOOP
    v_sql := format(
      'CREATE TABLE IF NOT EXISTS %I PARTITION OF %I FOR VALUES WITH (MODULUS 32, REMAINDER %s)',
      p_parent_name || '_h' || LPAD(i::text, 2, '0'),
      p_parent_name,
      i
    );
    EXECUTE v_sql;
  END LOOP;
END $$;

-- Generate hash sub-partitions for months 02..12
-- (month 01 was created manually above as an example)
SELECT fn_create_tran_hist_hash_partitions('wlt_tran_hist_2026_02');
SELECT fn_create_tran_hist_hash_partitions('wlt_tran_hist_2026_03');
SELECT fn_create_tran_hist_hash_partitions('wlt_tran_hist_2026_04');
SELECT fn_create_tran_hist_hash_partitions('wlt_tran_hist_2026_05');
SELECT fn_create_tran_hist_hash_partitions('wlt_tran_hist_2026_06');
SELECT fn_create_tran_hist_hash_partitions('wlt_tran_hist_2026_07');
SELECT fn_create_tran_hist_hash_partitions('wlt_tran_hist_2026_08');
SELECT fn_create_tran_hist_hash_partitions('wlt_tran_hist_2026_09');
SELECT fn_create_tran_hist_hash_partitions('wlt_tran_hist_2026_10');
SELECT fn_create_tran_hist_hash_partitions('wlt_tran_hist_2026_11');
SELECT fn_create_tran_hist_hash_partitions('wlt_tran_hist_2026_12');


-- #############################################################################
-- #                                                                           #
-- #   SECTION 7 — SEED DATA                                                   #
-- #                                                                           #
-- #############################################################################

-- ─────────────────────────────────────────────────────────────────────────────
-- 7.1  FM_CURRENCY
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO FM_CURRENCY (CCY, CCY_DESC, DECI_PLACES, DAY_BASIS, CCY_GROUP) VALUES
  ('VND', 'Vietnamese Dong', 2, 360, 'FIAT')
ON CONFLICT (CCY) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7.2  FM_GL_MAST — Chart of accounts
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO FM_GL_MAST (GL_CODE, GL_CODE_DESC, GL_CODE_TYPE, BSPL_TYPE, STATUS) VALUES
  ('101.02.001', 'Nostro @ Partner Bank (TKĐBTT)',         'A', 'B', 'A'),
  ('201.01.001', 'Customer Wallet — Consumer',             'L', 'B', 'A'),
  ('201.02.001', 'Customer Wallet — Merchant',             'L', 'B', 'A'),
  ('203.01',     'VAT Output Payable',                     'L', 'B', 'A'),
  ('401.01',     'Transfer Fee Revenue',                   'I', 'P', 'A'),
  ('401.02',     'Merchant Fee Revenue',                   'I', 'P', 'A'),
  ('401.03',     'Merchant Discount Rate Revenue',         'I', 'P', 'A')
ON CONFLICT (GL_CODE) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7.3  WLT_TRAN_DEF — transaction type definitions
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO WLT_TRAN_DEF VALUES
 ('TOPUP',  'Topup from bank',      'CR','RVTPUP', 'N','N','BANK',   '101.02.001', 10000, 500000000, 0,'Y','Topup',   'A', 'NONE',    0,       0,      0,    0,        0.00, NULL,      NULL,      NULL),
 ('TRFOUT', 'Internal transfer out','DR','RVTRF',  'Y','Y','MOBILE', NULL,         1000, 100000000, 0,'Y','Transfer','A', 'FIXED',   5500,    0,      0,    0,        0.10, '401.01',  '203.01',  'FEETRF'),
 ('TRFIN',  'Internal transfer in', 'CR','RVTRF',  'N','N','MOBILE', NULL,         1000, 100000000, 0,'Y','Transfer','A', 'NONE',    0,       0,      0,    0,        0.00, NULL,      NULL,      NULL),
 ('WDRAW',  'Withdraw to bank',     'DR','RVWD',   'Y','Y','MOBILE', '101.02.001', 50000,200000000, 0,'Y','Withdraw','A', 'PERCENT', 0,       0.001,  11000,55000,    0.10, '401.01',  '203.01',  'FEEWD'),
 ('FEETRF', 'Fee for transfer',    'DR','RVFEE',   'N','N','SYS',    '401.01',     0,    10000000,  0,'Y','Fee',     'A', 'NONE',    0,       0,      0,    0,        0.00, NULL,      NULL,      NULL),
 ('FEEWD',  'Fee for withdraw',    'DR','RVFEE',   'N','N','SYS',    '401.01',     0,    10000000,  0,'Y','Fee',     'A', 'NONE',    0,       0,      0,    0,        0.00, NULL,      NULL,      NULL),
 ('RVTPUP', 'Reverse topup',       'DR',NULL,      'N','N','SYS',    '101.02.001', 0,    500000000, 0,'Y','Reversal','A', 'NONE',    0,       0,      0,    0,        0.00, NULL,      NULL,      NULL),
 ('RVTRF',  'Reverse transfer',    'CR',NULL,      'N','N','SYS',    NULL,         0,    100000000, 0,'Y','Reversal','A', 'NONE',    0,       0,      0,    0,        0.00, NULL,      NULL,      NULL),
 ('RVWD',   'Reverse withdraw',    'CR',NULL,      'N','N','SYS',    '101.02.001', 0,    200000000, 0,'Y','Reversal','A', 'NONE',    0,       0,      0,    0,        0.00, NULL,      NULL,      NULL),
 ('RVFEE',  'Reverse fee',         'CR',NULL,      'N','N','SYS',    '401.01',     0,    10000000,  0,'Y','Reversal','A', 'NONE',    0,       0,      0,    0,        0.00, NULL,      NULL,      NULL),
 -- Sharding sweep (v1.6.3)
 ('SWEEPO', 'Sweep out from shard','DR','RVSWP',   'N','N','SYS',    NULL,         0,    1000000000,0,'Y','Sweep',   'A', 'NONE',    0,       0,      0,    0,        0.00, NULL,      NULL,      NULL),
 ('SWEEPI', 'Sweep in to settle',  'CR','RVSWP',   'N','N','SYS',    NULL,         0,    1000000000,0,'Y','Sweep',   'A', 'NONE',    0,       0,      0,    0,        0.00, NULL,      NULL,      NULL),
 ('RVSWP',  'Reverse sweep',       'CR',NULL,      'N','N','SYS',    NULL,         0,    1000000000,0,'Y','Reversal','A', 'NONE',    0,       0,      0,    0,        0.00, NULL,      NULL,      NULL),
 -- Merchant withdraw (v1.6.3)
 ('MERCHWD','Merchant withdraw',   'DR','RVMWD',   'Y','Y','SYS',    '101.02.001', 50000,2000000000,0,'Y','Withdraw','A', 'PERCENT', 0,       0.0005, 22000,110000,   0.10, '401.02',  '203.01',  'FEEMW'),
 ('FEEMW',  'Fee merchant WD',     'DR','RVFEE',   'N','N','SYS',    '401.02',     0,    10000000,  0,'Y','Fee',     'A', 'NONE',    0,       0,      0,    0,        0.00, NULL,      NULL,      NULL),
 ('RVMWD',  'Reverse merchant WD', 'CR',NULL,      'N','N','SYS',    '101.02.001', 0,    2000000000,0,'Y','Reversal','A', 'NONE',    0,       0,      0,    0,        0.00, NULL,      NULL,      NULL)
ON CONFLICT (TRAN_TYPE) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7.4  WLT_GL_MAP — wallet event → GL code mapping
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO WLT_GL_MAP VALUES
  ('CONSUMER','LIABILITY',  '201.01.001','Customer Wallet — Consumer'),
  ('CONSUMER','TOPUP_DR',   '101.02.001','Nostro @ Bank B'),
  ('CONSUMER','WITHDRAW_CR','101.02.001','Nostro @ Bank B'),
  ('CONSUMER','FEE_CR',     '401.01',    'Transfer fee revenue'),
  ('MERCHANT','LIABILITY',  '201.02.001','Merchant Wallet'),
  ('MERCHANT','MDR_CR',     '401.03',    'Merchant discount rate')
ON CONFLICT (ACCT_TYPE, EVENT_TYPE) DO NOTHING;


-- #############################################################################
-- #                                                                           #
-- #   SECTION 8 — VERIFICATION                                                #
-- #                                                                           #
-- #############################################################################

-- Table count summary
-- SELECT schemaname, tablename FROM pg_tables
--  WHERE tablename LIKE 'fm_%' OR tablename LIKE 'wlt_%'
--  ORDER BY tablename;

-- Entity count:
--   FM tables:     8  (FM_CLIENT, FM_CLIENT_INDVL, FM_CLIENT_IDENTIFIERS,
--                      FM_CLIENT_CONTACT, FM_CLIENT_BANKS,
--                      FM_CURRENCY, FM_GL_MAST, FM_NOS_VOS)
--   WLT tables:   19  (WLT_CLIENT_KYC, WLT_ACCT_TYPE, WLT_ACCT_GROUP,
--                      WLT_ACCT, WLT_ACCT_BAL, WLT_TRAN_DEF, WLT_TRAN_HIST,
--                      WLT_BATCH, WLT_RESTRAINTS, WLT_SWEEP_LOG, WLT_GL_MAP,
--                      WLT_NOSTRO_LINK, WLT_NOSTRO_BAL, WLT_RECON_BREAK,
--                      WLT_API_MESSAGE, WLT_API_TRACE, WLT_OUTBOX,
--                      WLT_WITHDRAW_TRACK, WLT_STMT_DETAIL,
--                      WLT_CLIENT_AUDIT_LOG)
--   Views:         2  (v_wlt_group_balance, v_wlt_active_restraints_effective)
--   Functions:     2  (fn_audit_client_change, fn_create_tran_hist_hash_partitions)
--   Triggers:      1  (trg_audit_wlt_kyc)
--   Sequences:     1  (seq_tfr)
--   Total:        27 entities + 2 views + 2 functions + 1 trigger + 1 sequence
-- =============================================================================
