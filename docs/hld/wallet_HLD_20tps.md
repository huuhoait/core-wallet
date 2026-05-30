# High-Level Design — Core Wallet (20 TPS scope)

**Version**: 1.0
**Date**: 2026-05-28
**Status**: Draft
**Author**: Core Wallet Team
**Scope**: Y1 launch — 20 TPS peak, 1–2M active customers
**Reference**: `wallet_HLD.md` (comprehensive 2K/5K TPS design), `wallet_DLD.md` (table-level DDL)

---

## 0. Tại sao bản này tồn tại

`wallet_HLD.md` là spec đầy đủ cho 2.000 TPS sustained / 5.000 TPS peak với roadmap 14M customers Y5. Cho **Y1 launch ở 20 TPS peak** (~1–2M customers), nhiều pattern trong đó là premature engineering.

Tài liệu này **scope lại**:
- **Giữ** mọi correctness primitive (atomicity, idempotency, PII protection, compliance, audit) — không phụ thuộc TPS.
- **Hoãn** mọi pattern phức tạp được thiết kế cho TPS cao (Debezium, sharding, warm tier, multi-tier lifecycle, materialized counters).
- **Đơn giản hoá** vận hành (1 monitoring dashboard, weekly restore-test, partition tạo tay 6 tháng).

Khi TPS thật sự chạm các trigger trong §13, migrate lên patterns trong `wallet_HLD.md`. Schema DDL giữ nguyên — không cần data migration.

---

## 1. Mục tiêu & Phạm vi

### 1.1 Business objectives (không đổi từ HLD gốc)
Build a **Core Wallet** system that manages e-wallet accounts and processes:
- **Top-up** (load funds — Treasury service confirms ingress)
- **Transfer** (wallet ↔ wallet, in-book)
- **Withdraw** (to bank, sync commit + async settlement via Treasury)
- **Payment** (to merchants)
- **Fee & VAT** (10% VAT on payment-intermediary services)
- **Reversal / Refund**

### 1.2 Technical objectives — Y1 calibration

| Target | HLD gốc (2K/5K TPS) | **Bản này (20 TPS)** |
|--------|---------------------|----------------------|
| Throughput | 2.000 TPS sustained, 5.000 TPS peak | **20 TPS peak**, 5 TPS sustained avg |
| Latency p50 | < 100 ms | < 100 ms |
| Latency p99 | < 300 ms | < 250 ms (network-dominated) |
| Availability | 99.95% | **99.9%** (đủ cho Y1 single-region active-passive) |
| RTO | ≤ 15 phút | ≤ 30 phút (manual DR failover OK) |
| RPO | ≤ 1 phút | ≤ 5 phút (continuous WAL archive đủ) |
| Customer base Y1 | 3M | **1–2M** |
| Data volume Y1 | 600M tran/year | **~60M tran/year** |

### 1.3 Out of scope (giữ nguyên HLD gốc)
- Physical card system, lending/credit, term deposit, crypto
- **External payment integration**: NAPAS callback, partner banks, card 3DS, MoMo/ZaloPay, MT940 — split sang **Treasury Service** spec riêng
- Multi-currency (Y2+)

### 1.4 FM (Foundation Master) integration
- `FM_CLIENT` = customer master (golden source)
- `FM_GL_MAST` = chart of accounts
- `FM_NOS_VOS` = nostro master (TKĐBTT)
- `FM_CURRENCY` = CCY config (VND-only Y1)

---

## 2. Sizing & Cost Recommendation (NEW)

### 2.1 Workload sizing

| Metric | Value |
|--------|-------|
| Peak TPS | 20 |
| Average TPS (business hours) | 5–8 |
| Daily volume | ~500K–1M tran |
| Monthly volume | ~15–25M tran |
| Active customers | 1–2M |
| Active wallets | 1–2M (ratio ~1.05) |
| WLT_TRAN_HIST growth | ~6 GB/year (3 legs × ~280 B × 25M tran/month avg) |
| WLT_BATCH growth | ~10 GB/year (5 GL legs × ~110 B) |
| Total OLTP DB size Y1 | ~25–35 GB |
| Total OLTP DB size Y2 | ~70 GB (with 3× growth) |

### 2.2 Hardware recommendation

| Component | Spec | Quantity | Lý do |
|-----------|------|----------|-------|
| **PG Primary** | 4 vCPU / 16 GB / 200 GB gp3 (5000 IOPS) | 1 | Dư 5–10× headroom cho 20 TPS |
| **PG Sync Standby** (same AZ) | Identical | 1 | RPO ~0, auto-failover via Patroni |
| **PG DR Replica** (different region) | 2 vCPU / 8 GB / 200 GB gp3 | 1 | Catastrophic failover; manual promote |
| **PgBouncer** | 1 vCPU / 1 GB | 1 (or sidecar) | Transaction-mode pooling, bắt buộc |
| **App pods (Go)** | 2 vCPU / 2 GB | 2 | HA |
| **API Gateway** (Kong/APISIX) | 1 vCPU / 1 GB | 2 | TLS + auth + rate limit |
| **Kafka** | t3.medium × 3 (or MSK serverless) | 1 cluster | Outbox + downstream events |
| **Redis** | 1 GB managed | 1 | Rate-limit counters, **không phải** balance source |
| **Monitoring stack** | Prometheus + Grafana + Loki | shared | OSS, single dashboard |

### 2.3 Cost envelope (AWS, 2026 pricing)

| Item | $/month |
|------|---------|
| PG Primary + Sync Standby | $500 |
| PG DR Replica (cross-region) | $200 |
| App pods + PgBouncer + API GW | $200 |
| Kafka (MSK serverless 3-broker) | $400 |
| Redis managed | $50 |
| Backup storage (S3 + WAL archive) | $50 |
| KMS key usage | $20 |
| Cross-region data egress | $100 |
| Monitoring (managed Grafana) | $200 |
| **Total infrastructure** | **~$1.700/month (~$20K/year)** |

So với engineering team cost (~$150–300K/year) — infrastructure là chi phí nhỏ. **Không skimp gp3 IOPS hoặc HA replica để tiết kiệm $200/tháng**.

### 2.4 Team sizing

| Role | FTE Y1 |
|------|--------|
| Backend engineer (Go + plpgsql SP) | 2 |
| DBA / Platform engineer | 0.5 |
| DevOps / SRE | 0.5 |
| Compliance / DPO liaison | 0.25 |
| **Total** | **3.25 FTE** |

### 2.5 Latency expectations ở 20 TPS

| Metric | p50 | p99 |
|--------|-----|-----|
| SP wall-clock | 5–7 ms | 12–18 ms |
| Server-side total (Go in → out) | 8–12 ms | 25 ms |
| End-to-end (mobile network included) | 70–100 ms | 150–200 ms |
| Outbox lag (polling worker, 60s) | < 60 s | < 90 s |
| Sync replica lag | < 50 ms | < 200 ms |
| Async DR replica lag | < 5 s | < 30 s |

→ Tất cả nằm gọn trong target NFR §9.

---

## 3. Stakeholders & Actors

| Stakeholder | Role |
|-------------|------|
| End User | Customer holding wallet |
| Merchant | Corporate receiving payments |
| Partner Bank | Holds TKĐBTT (nostro) |
| Treasury Service | Bridges wallet ↔ external (out of scope) |
| SBV (State Bank of Vietnam) | Regulator |
| Ops / Finance / Compliance | Internal teams |

---

## 4. System Context

```
                  ┌──────────────────────────────────────┐
                  │   Internal upstream (in scope)        │
                  │  ┌──────────────┐  ┌──────────────┐  │
                  │  │ Customer App │  │ Ops Console  │  │
                  │  └──────┬───────┘  └───────┬──────┘  │
                  └─────────┼──────────────────┼─────────┘
                            │                  │
                ┌───────────▼──────────────────▼─────────┐
                │       API Gateway (REST + auth)         │
                │   + Rate limit + AuthN/AuthZ + Audit   │
                └─────────────────┬──────────────────────┘
                                  │
                ┌─────────────────▼──────────────────────┐
                │   Go Service (2 pods, thin RPC client)  │
                │   + PgBouncer (transaction mode)        │
                └─────────────────┬──────────────────────┘
                                  │
                ┌─────────────────▼──────────────────────┐
                │   PostgreSQL 17 Primary                  │
                │   (Posting SPs run here)                 │
                │   + Sync Standby (same AZ)               │
                │   + Async DR Replica (different region)  │
                └─────────────────┬──────────────────────┘
                                  │
                ┌─────────────────▼──────────────────────┐
                │   Outbox Polling Worker (Go, Y1)        │
                │   SELECT FOR UPDATE SKIP LOCKED ─────► Kafka
                │   Migrate to Debezium when > 500 TPS    │
                └─────────────────┬──────────────────────┘
                                  │
                ┌─────────────────▼──────────────────────┐
                │   Kafka (3-broker MSK serverless)        │
                │   Topics: wallet.transactions,           │
                │           wallet.withdrawals,            │
                │           wallet.restraints              │
                └────────┬─────────────────────────────────┘
                         │
        ┌────────────────┼──────────────────────────────────┐
        │ Internal downstream (in scope)                     │
        │  • Notification • DW • Fraud monitoring            │
        │  • GL feed to FM_GL_MAST • Statement gen           │
        └────────────────┼──────────────────────────────────┘
                         │
        ┌────────────────▼──────────────────────────────────┐
        │ External boundary (OUT OF SCOPE — Treasury spec)   │
        │  • Treasury: consume withdraw.posted               │
        │    → batch NAPAS payout → MT940 T+1 recon          │
        │    → callback mark_withdraw_acked/completed/failed │
        │  • Topup gateway: confirm s2s → POST /topup        │
        └────────────────────────────────────────────────────┘
```

### 4.1 Khác biệt vs HLD gốc

| Element | HLD gốc | Bản 20 TPS |
|---------|---------|-----------|
| Outbox relay | Debezium CDC primary | **Polling worker** (defer Debezium) |
| App pods | Scale-out 4+ pods | 2 pods (HA) |
| PG cluster | 8 vCPU primary + multi-AZ + cross-region | 4 vCPU primary + sync standby + DR replica |
| Sub-account sharding | Active cho merchant > 30 TPS | **Defer** — không có merchant nào > 30 TPS ở scale này |

---

## 5. 2-tier FM + WLT (giữ nguyên HLD gốc §3a)

Không thay đổi. FM = master (slow-changing, shared), WLT = transactional (fast, wallet-only).

```
WLT (transactional) ──FK──▶ FM (master, read-only from WLT)
```

**FK rules**:
- WLT chỉ SELECT từ FM
- Mọi mutation FM đi qua FM Admin Service với maker-checker
- `WLT_CLIENT_AUDIT_LOG` trigger có thể attach lên FM_CLIENT* nếu coordinate được với FM team

---

## 6. Logical modules — Y1 scope

| # | Module | Y1 status |
|---|--------|-----------|
| 1 | API Gateway | ✅ Full |
| 2 | Foundation Master (FM) | ✅ Reuse / build if greenfield |
| 3 | Account Management | ✅ Full |
| 4 | Posting Engine (plpgsql SP) | ✅ Full |
| 5 | Fee & VAT Engine | ✅ Full (VND-only) |
| 6 | Ledger / GL Feed | ✅ Basic (batch push to FM_GL_MAST); EOD close → Phase 2 |
| 7 | Reconciliation | ✅ Daily nostro vs ledger; break workflow → Phase 2 |
| 8 | Statement / Reporting | ✅ Customer statement; SBV reports → Phase 2 |
| 9 | Notification | ✅ Push + SMS via Kafka consumer |

---

## 7. Data architecture

### 7.1 ERD — Y1 scope

```mermaid
erDiagram
    %% ===== FM tier (master) =====
    FM_CLIENT             ||--o| FM_CLIENT_INDVL        : "extends (individual)"
    FM_CLIENT             ||--o{ FM_CLIENT_IDENTIFIERS  : "has IDs"
    FM_CLIENT             ||--o{ FM_CLIENT_CONTACT      : "has contacts"
    FM_CLIENT             ||--o{ FM_CLIENT_BANKS        : "linked banks"
    FM_GL_MAST            ||--o{ FM_GL_MAST             : "parent GL"
    FM_GL_MAST            ||--o{ FM_NOS_VOS             : "nostro GL"
    FM_CURRENCY           ||--o{ FM_NOS_VOS             : "ccy"

    %% ===== FM ↔ WLT crossings =====
    FM_CLIENT             ||--o{ WLT_CLIENT_KYC         : "kyc info"
    FM_CLIENT             ||--o{ WLT_ACCT               : "owns wallet"
    FM_CLIENT             ||--o{ WLT_ACCT_GROUP         : "owns merchant/agent group"
    FM_CLIENT             ||--o{ WLT_CLIENT_AUDIT_LOG   : "change history"
    FM_CURRENCY           ||--o{ WLT_ACCT               : "ccy"
    FM_CURRENCY           ||--o{ WLT_BATCH              : "ccy"
    FM_GL_MAST            ||--o{ WLT_ACCT_TYPE          : "liability GL"
    FM_GL_MAST            ||--o{ WLT_BATCH              : "GL feed target"
    FM_GL_MAST            ||--o{ WLT_GL_MAP             : "GL ref"
    FM_GL_MAST            ||--o{ WLT_TRAN_DEF           : "fee/VAT GL"
    FM_NOS_VOS            ||--|| WLT_NOSTRO_LINK        : "nostro alias"

    %% ===== WLT tier — master/reference =====
    WLT_ACCT_TYPE         ||--o{ WLT_ACCT               : "classifies"
    WLT_ACCT_GROUP        ||--o{ WLT_ACCT               : "shards + settlement"
    WLT_ACCT_GROUP        ||--o{ WLT_RESTRAINTS         : "group-level scope"
    WLT_ACCT_GROUP        ||--o{ WLT_SWEEP_LOG          : "sweep audit"
    WLT_TRAN_DEF          ||--o{ WLT_TRAN_HIST          : "tran type"
    WLT_CLIENT_KYC        ||--o{ WLT_CLIENT_AUDIT_LOG   : "change history"

    %% ===== WLT tier — transactional =====
    WLT_ACCT              ||--o{ WLT_ACCT_BAL           : "daily snapshot"
    WLT_ACCT              ||--o{ WLT_TRAN_HIST          : "posts"
    WLT_ACCT              ||--o{ WLT_RESTRAINTS         : "acct-level scope"
    WLT_TRAN_HIST         ||--o{ WLT_BATCH              : "GL legs"
    WLT_TRAN_HIST         ||--o| WLT_WITHDRAW_TRACK     : "disbursement state (withdraw only)"
    WLT_TRAN_HIST         ||--o{ WLT_OUTBOX             : "emits event (same TX)"
    WLT_API_MESSAGE       ||--o{ WLT_TRAN_HIST          : "idempotency origin"
    WLT_NOSTRO_LINK       ||--o{ WLT_NOSTRO_BAL         : "daily recon"

    %% ===== Entities =====
    FM_CLIENT {
        VARCHAR  CLIENT_NO  PK
        VARCHAR  GLOBAL_ID
        VARCHAR  GLOBAL_ID_TYPE
        VARCHAR  CLIENT_NAME
        VARCHAR  CLIENT_TYPE
        VARCHAR  COUNTRY_LOC
        VARCHAR  STATUS
    }
    FM_CLIENT_INDVL {
        VARCHAR  CLIENT_NO  PK_FK
        VARCHAR  SURNAME
        VARCHAR  GIVEN_NAME_1
        DATE     BIRTH_DATE
        VARCHAR  RESIDENT_STATUS
    }
    FM_CLIENT_IDENTIFIERS {
        VARCHAR  CLIENT_NO  PK_FK
        VARCHAR  GLOBAL_ID  PK
        VARCHAR  GLOBAL_ID_TYPE PK
        DATE     EXPIRY_DATE
        SMALLINT IS_CURRENT
    }
    FM_CLIENT_CONTACT {
        VARCHAR CLIENT_NO PK_FK
        VARCHAR CONTACT_TYPE PK
        VARCHAR ADDR_LINE1
        VARCHAR PHONE_NO_ENC
        VARCHAR EMAIL_ENC
    }
    FM_CLIENT_BANKS {
        VARCHAR  CLIENT_NO PK_FK
        SMALLINT SEQ_NO PK
        VARCHAR  BANK_CODE
        VARCHAR  ACCT_NO_ENC
    }
    FM_CURRENCY {
        VARCHAR  CCY  PK
        SMALLINT DECI_PLACES
        SMALLINT DAY_BASIS
    }
    FM_GL_MAST {
        VARCHAR GL_CODE  PK
        VARCHAR GL_CODE_TYPE
        VARCHAR BSPL_TYPE
        VARCHAR CONTROL_GL_CODE FK
    }
    FM_NOS_VOS {
        BIGINT  NOS_VOS_NO  PK
        VARCHAR ACCT_TYPE
        VARCHAR CCY FK
        VARCHAR GL_CODE FK
        VARCHAR ACCT_NO
    }

    WLT_CLIENT_KYC {
        BIGINT      KYC_ID PK
        VARCHAR     CLIENT_NO FK
        VARCHAR     PHONE_NO_ENC
        VARCHAR     EMAIL_ENC
        VARCHAR     KYC_TIER
        VARCHAR     RISK_LEVEL
        TIMESTAMPTZ VERIFIED_AT
    }
    WLT_ACCT_TYPE {
        VARCHAR ACCT_TYPE PK
        VARCHAR GL_CODE_LIAB FK
        NUMERIC DAILY_LIMIT
        NUMERIC MONTHLY_LIMIT
    }
    WLT_ACCT_GROUP {
        VARCHAR  GROUP_ID PK
        VARCHAR  CLIENT_NO FK
        VARCHAR  GROUP_TYPE
        SMALLINT SHARD_COUNT
        VARCHAR  SETTLEMENT_ACCT_NO FK
    }
    WLT_ACCT {
        BIGINT   INTERNAL_KEY PK
        VARCHAR  ACCT_NO UK
        VARCHAR  CLIENT_NO FK
        VARCHAR  ACCT_TYPE FK
        VARCHAR  CCY FK
        NUMERIC  ACTUAL_BAL
        NUMERIC  TOTAL_RESTRAINED_AMT
        NUMERIC  CALC_BAL
        VARCHAR  CR_BLOCKED
        INT      VERSION
        VARCHAR  GROUP_ID FK
        SMALLINT SHARD_INDEX
        VARCHAR  ACCT_ROLE
    }
    WLT_ACCT_BAL {
        BIGINT  INTERNAL_KEY PK_FK
        DATE    TRAN_DATE PK
        NUMERIC ACTUAL_BAL
        NUMERIC CALC_BAL
    }
    WLT_TRAN_DEF {
        VARCHAR TRAN_TYPE PK
        VARCHAR CR_DR_MAINT_IND
        VARCHAR REVERSAL_TRAN_TYPE
        VARCHAR FEE_TYPE
        NUMERIC FEE_AMT
        NUMERIC FEE_RATE
        NUMERIC VAT_RATE
        VARCHAR FEE_GL_CODE FK
        VARCHAR VAT_GL_CODE FK
        VARCHAR FEE_TRAN_TYPE
    }
    WLT_TRAN_HIST {
        BIGINT  INTERNAL_KEY PK_FK
        BIGINT  SEQ_NO PK
        DATE    POST_DATE PK
        VARCHAR TRAN_TYPE FK
        NUMERIC TRAN_AMT
        VARCHAR CR_DR_MAINT_IND
        BIGINT  TFR_INTERNAL_KEY
        VARCHAR REFERENCE
        JSONB   METADATA
        JSONB   CLIENT_INFO
    }
    WLT_BATCH {
        BIGINT  TRAN_KEY PK
        BIGINT  SEQ_NO PK
        VARCHAR GL_CODE FK
        VARCHAR CCY FK
        NUMERIC AMOUNT
        VARCHAR TRAN_NATURE
        DATE    POST_DATE
    }
    WLT_RESTRAINTS {
        BIGINT  SEQ_NO PK
        BIGINT  INTERNAL_KEY FK
        VARCHAR GROUP_ID FK
        VARCHAR RESTRAINT_TYPE
        NUMERIC PLEDGED_AMT
        VARCHAR STATUS
    }
    WLT_API_MESSAGE {
        BIGINT      SEQ_NO PK
        VARCHAR     OBJECT_REF_ID UK
        VARCHAR     OBJECT_SUBJECT
        VARCHAR     PROCESS_STATUS
        TEXT        OBJECT_RESPONE_DATA
        TIMESTAMPTZ OBJECT_DATE
    }
    WLT_OUTBOX {
        BIGINT      EVENT_ID PK
        UUID        EVENT_UUID UK
        VARCHAR     AGGREGATE_TYPE
        VARCHAR     AGGREGATE_ID
        VARCHAR     EVENT_TYPE
        VARCHAR     PARTITION_KEY
        VARCHAR     TOPIC
        JSONB       PAYLOAD
        VARCHAR     STATUS
        TIMESTAMPTZ CREATED_AT PK
    }
    WLT_WITHDRAW_TRACK {
        BIGINT      TFR_INTERNAL_KEY PK
        VARCHAR     ACCT_NO
        VARCHAR     CLIENT_NO
        NUMERIC     AMOUNT
        NUMERIC     FEE_GROSS
        VARCHAR     EXT_PAYOUT_REF UK
        BYTEA       BENEFICIARY_ACCT_ENC
        VARCHAR     STATUS
        TIMESTAMPTZ ACK_DEADLINE
        TIMESTAMPTZ FINAL_DEADLINE
        INT         VERSION
    }
    WLT_NOSTRO_LINK {
        VARCHAR NOSTRO_ID PK
        BIGINT  NOS_VOS_NO FK
        VARCHAR GL_CODE FK
        VARCHAR STATUS
    }
    WLT_NOSTRO_BAL {
        VARCHAR NOSTRO_ID PK_FK
        DATE    BAL_DATE PK
        NUMERIC BANK_REPORTED_BAL
        NUMERIC LEDGER_BAL
        NUMERIC DIFF_AMT
    }
    WLT_GL_MAP {
        VARCHAR ACCT_TYPE PK
        VARCHAR EVENT_TYPE PK
        VARCHAR GL_CODE FK
    }
    WLT_SWEEP_LOG {
        BIGINT      SEQ_NO PK
        VARCHAR     GROUP_ID FK
        VARCHAR     SHARD_ACCT_NO
        NUMERIC     SWEPT_AMOUNT
        VARCHAR     TRIGGER_TYPE
        VARCHAR     STATUS
        TIMESTAMPTZ CREATED_AT
    }
    WLT_CLIENT_AUDIT_LOG {
        BIGINT      AUDIT_ID PK
        VARCHAR     CLIENT_NO FK
        VARCHAR     TABLE_NAME
        VARCHAR     OPERATION
        TIMESTAMPTZ CHANGED_AT PK
        VARCHAR     CHANGED_BY
        VARCHAR     CHANGE_SOURCE
        JSONB       OLD_VALUES
        JSONB       NEW_VALUES
        TEXT        CHANGED_FIELDS
        VARCHAR     MAKER_ID
        VARCHAR     CHECKER_ID
    }
```

> Cardinality cheatsheet:
> - 1 `FM_CLIENT` → N `WLT_ACCT` (one customer, multiple wallets)
> - 1 transfer transaction → 3 `WLT_TRAN_HIST` rows (DR + CR + FEETRF) linked by `TFR_INTERNAL_KEY`
> - 1 withdraw transaction → 2 `WLT_TRAN_HIST` + 1 `WLT_WITHDRAW_TRACK` + 5 `WLT_BATCH` + 1 `WLT_OUTBOX`
> - 1 atomic posting → exactly 1 `WLT_OUTBOX` row (`AGGREGATE_ID = TFR_INTERNAL_KEY`)
> - 1 client-table mutation → 1 `WLT_CLIENT_AUDIT_LOG` row (via trigger)

### 7.1.1 Table inventory by category

```
FM TIER (read-only from WLT, FK target only)
  Customer:    FM_CLIENT, FM_CLIENT_INDVL, FM_CLIENT_IDENTIFIERS,
               FM_CLIENT_CONTACT, FM_CLIENT_BANKS
  Reference:   FM_CURRENCY, FM_GL_MAST, FM_NOS_VOS

WLT TIER
  Master:      WLT_ACCT_TYPE, WLT_CLIENT_KYC, WLT_TRAN_DEF, WLT_GL_MAP,
               WLT_NOSTRO_LINK, WLT_ACCT_GROUP
  Account:     WLT_ACCT, WLT_ACCT_BAL
  Ledger:      WLT_TRAN_HIST, WLT_BATCH
  Control:     WLT_RESTRAINTS, WLT_API_MESSAGE
  Async:       WLT_OUTBOX, WLT_WITHDRAW_TRACK
  Audit:       WLT_CLIENT_AUDIT_LOG, WLT_SWEEP_LOG
  Recon:       WLT_NOSTRO_BAL
```

> **Y1 ghi chú**: `WLT_ACCT_GROUP` + `WLT_SWEEP_LOG` được **tạo bảng ngay từ đầu** với `ACCT_ROLE='STANDALONE'` mặc định cho mọi wallet — schema future-proof, không cần ALTER khi enable sharding. Application logic cho sharding (`provision_acct_group`, `post_sweep_shard`) chỉ implement khi trigger §13.2 đạt ngưỡng.

> **SQL script**: schema deploy-ready ở `wallet_schema.sql` (cùng thư mục) — chạy 1 lần là dựng được toàn bộ.

### 7.2 Partitioning — simplified for Y1

`WLT_TRAN_HIST` vẫn partition by month + hash(INTERNAL_KEY) × 32 như HLD gốc DDL (giữ nguyên DDL, không phải migrate sau này). Khác biệt Y1:

- **Manual partition creation** trước 6 tháng. Không cần `pg_partman` cho đến khi DB > 100 GB.
- **Không** MERGE PARTITION yearly (chưa cần).
- **Không** DETACH + archive (chưa cần).

`WLT_OUTBOX`, `WLT_CLIENT_AUDIT_LOG`, `WLT_ACCT_BAL`: cũng monthly partition, tạo tay.

### 7.3 Data principles (giữ nguyên HLD gốc §5.2)

1. Single source of truth (balance, customer, GL, nostro)
2. Append-only `WLT_TRAN_HIST`
3. Idempotent (REFERENCE unique)
4. Atomic (1 business tran = 1 DB tran)
5. Auditability (`WLT_OLTP_AUDIT` + `WLT_API_TRACE` + `WLT_CLIENT_AUDIT_LOG`)
6. Time-aware (`TRAN_DATE` ≠ `EFFECT_DATE` ≠ `POST_DATE` ≠ `VALUE_DATE`)
7. FM read-only from WLT
8. Point-in-time customer snapshot (`CLIENT_INFO` JSONB)
9. Open metadata bag (`METADATA` JSONB, P1-forbidden)

---

## 8. Business flows

### 8.1 Top-up (internal credit from Treasury)

```
Treasury Service → POST /v1/transactions/topup (s2s auth)
                    → post_topup SP
                       ├─► Phase 1: validate (no lock) — status, CR-restraint
                       ├─► Phase 2: atomic
                       │   ├─► UPDATE WLT_ACCT (+amount, VERSION++)
                       │   ├─► INSERT WLT_TRAN_HIST × 1 (TOPUP)
                       │   ├─► INSERT WLT_BATCH × 2 (DR nostro / CR wallet)
                       │   ├─► INSERT WLT_OUTBOX
                       │   └─► COMMIT
                       └─► 200 POSTED
```

### 8.2 Wallet → wallet transfer (in-book, with fee + VAT)

```
User A → App → API GW → post_transfer SP
                         ├─► Phase 1: validate × 2 wallets (no lock)
                         ├─► Phase 2: atomic
                         │   ├─► UPDATE WLT_ACCT × 2 ordered by INTERNAL_KEY ASC
                         │   ├─► INSERT WLT_TRAN_HIST × 3 (DR A, CR B, FEETRF A)
                         │   ├─► INSERT WLT_BATCH × 5 (DR/CR + 3 fee/VAT legs)
                         │   ├─► UPSERT WLT_ACCT_BAL × 2
                         │   ├─► INSERT WLT_OUTBOX
                         │   └─► COMMIT
                         └─► 200 POSTED
```

### 8.3 Withdraw (sync commit + async settlement)

```
[Wallet ledger — IN SCOPE]
User → App → POST /withdraw → post_withdraw SP
              ├─► Phase 1: validate (no lock) — tier 2, DR-restraint, fund (incl fee+VAT)
              ├─► Phase 2: atomic
              │   ├─► UPDATE WLT_ACCT (-amount-fee, VERSION++)
              │   ├─► INSERT WLT_TRAN_HIST × 2 (WDRAW + FEEWD)
              │   ├─► INSERT WLT_BATCH × 5
              │   ├─► INSERT WLT_WITHDRAW_TRACK(STATUS='SUBMITTED',
              │   │           ACK_DEADLINE=NOW()+60s, FINAL_DEADLINE=NOW()+24h)
              │   ├─► INSERT WLT_OUTBOX(event='wallet.withdraw.posted.v1')
              │   └─► COMMIT
              └─► 200 POSTED

[Async — Treasury notifies wallet (mechanism per Treasury spec)]
  mark_withdraw_acked(ext_ref, batch_id)        → STATUS='ACKED'
  mark_withdraw_disbursing(ext_ref)             → STATUS='DISBURSING'
  mark_withdraw_completed(ext_ref, napas_ref)   → STATUS='COMPLETED' (terminal)
  post_withdraw_reversal(ext_ref, fail_code...) → STATUS='REVERSED' (terminal)
                                                  + credit-back + outbox event

[SLA safety net — pg_cron every 60s]
  ACK overdue (> 60s)        → alert P2
  FINAL overdue (> 24h)      → auto post_withdraw_reversal('SLA_TIMEOUT')
                              → customer refunded, never stuck
```

### 8.4 Fee & VAT posting

Cấu hình fee + VAT live trong `WLT_TRAN_DEF`. Mỗi transaction có fee tạo thêm 3 legs:

```
Original transfer 1M, FEE=5,500 gross, VAT_RATE=0.10:
   Leg 1: DR Wallet A   1,000,000     (transfer amount)
   Leg 2: CR Wallet B   1,000,000     (transfer amount)
   Leg 3: DR Wallet A       5,500     (fee + VAT total)
   Leg 4: CR GL 401.01      5,000     (Fee revenue net of VAT)
   Leg 5: CR GL 203.01        500     (VAT output payable)
```

VAT remittance hàng tháng: DR `GL 203.01` / CR operational nostro.

### 8.5 Reversal / Refund

- Reversal **không UPDATE** original row
- Generate 2 new rows (DR↔CR flipped), `REVERSAL_TRAN_TYPE` link via `TFR_INTERNAL_KEY`
- Nếu original có fee + VAT → reversal **phải refund cả fee + VAT** (3 reversed legs)
- `post_withdraw_reversal` idempotent on `EXT_PAYOUT_REF`

---

## 9. Non-Functional Requirements — Y1 calibration

| NFR | Y1 Target | Cách đạt được |
|-----|-----------|---------------|
| **Availability** | 99.9% (≤ 8.8h downtime/year) | Sync standby auto-failover via Patroni; manual DR failover |
| **Throughput** | 20 TPS peak | Dư 5–10× headroom trên 4c/16GB |
| **Latency** | p50 < 100 ms, p99 < 250 ms (in-book) | Deferred locking, ~1 ms lock window |
| **Recovery** | RTO ≤ 30 phút, RPO ≤ 5 phút | Continuous WAL archive + manual DR promote |
| **Data retention** | 18 months online, 10 years archive | Y1 chưa cần archive — basic monthly partition + daily backup là đủ |
| **Encryption** | TLS 1.3 transit, AES-256 at rest, column-level PII | KMS-managed DEK (§10.3) |
| **PII protection** | Decree 13/2023 + Cybersecurity Law 2018 | §10.3 inherits từ HLD gốc §8.3 không đổi |
| **Audit** | 100% transactions traceable; client-info changes captured by trigger | `WLT_OUTBOX` + `WLT_CLIENT_AUDIT_LOG` |
| **Compliance** | Decree 52/2024, Circular 23/2019, ISO 27001 | Full |

---

## 10. Compliance & Risk

### 10.1 Vietnamese legal framework (giữ nguyên HLD gốc §8.1)

- **TKĐBTT**: mandatory segregation (`FM_NOS_VOS` with `ACCT_TYPE='TKDBTT'`)
- **Mandatory equation**: `Σ TKĐBTT ≥ Σ customer wallet balances`
- **VAT 10%**: published tariff is VAT-inclusive, VAT split into `GL 203.01 VAT payable`
- **KYC tier**: Tier 1 (phone) 20M/month, Tier 2 (CCCD + eKYC) 100M/month, Tier 3 (biometric) per contract
- **AML/CFT**: CTR/STR reporting to SBV

### 10.2 Risk register (subset of HLD gốc §8.2, Y1-relevant)

| Risk | Mitigation |
|------|-----------|
| Double posting via retry | `WLT_API_MESSAGE.OBJECT_REF_ID` unique + idempotency gate ở Phase 1 SP |
| Race condition on balance | VERSION CAS in posting SP |
| TKĐBTT < total wallet | Daily recon job + alert |
| Disaster (primary DC loss) | Sync standby (same AZ) + DR replica (different region) |
| **Kafka event dropped** | `WLT_OUTBOX` transactional outbox + polling relay |
| **Withdraw debited but never disbursed** | `WLT_WITHDRAW_TRACK` + SLA janitor auto-reverse at 24h |
| Unauthorized PII access | Column encryption + RBAC + audit log §10.3 |
| Unauthorized client-info change | `WLT_CLIENT_AUDIT_LOG` trigger + maker-checker fields |

### 10.3 PII Protection (inherits HLD gốc §8.3 verbatim)

- Data classification (P1–P4)
- KMS-managed column encryption cho mọi P1
- TLS 1.3 + mTLS internal
- 3 DB roles: `wallet_app` / `wallet_pii_ro` / `wallet_admin`
- Masking views (`v_client_masked`, `v_kyc_masked`)
- `WLT_PII_ACCESS_LOG` immutable WORM
- 72h breach notification SLA to MPS (Decree 13/2023)
- Audit của client-info changes via `WLT_CLIENT_AUDIT_LOG` trigger (§10.4)

### 10.4 Client-info change audit (NEW vs gốc)

Mọi INSERT/UPDATE/DELETE trên `WLT_CLIENT_KYC` (và recommended FM_CLIENT* via coordination) đi qua trigger `fn_audit_client_change`:

- OLD/NEW JSONB + diff `CHANGED_FIELDS[]`
- Application set `SET LOCAL audit.actor/source/reason/maker_id/checker_id` per TX
- Audit table SECURITY DEFINER write-only — DBA không UPDATE/DELETE được
- Decoupled từ posting path (không gọi từ post_* SPs)

Alerts:
- `CHANGE_SOURCE='SP_BACKFILL'` (missing middleware) → P2
- KYC tier downgrade without `APPROVAL_REF` → P1

---

## 11. Tech Stack — Y1 simplified

| Layer | Choice | Lý do |
|-------|--------|-------|
| API Gateway | Kong / APISIX | Mature, plugin-rich |
| Service runtime | Go 1.23 + chi | Goroutine concurrency, low memory |
| Posting logic | **plpgsql stored functions** | 1 round-trip, atomic Phase 1+2 |
| DB driver | pgx/v5 + pgxpool | Native PG protocol |
| **Connection pool** | **PgBouncer transaction mode** | Bắt buộc — multiplex connections |
| Caller timeout | `context.WithTimeout(3s)` | Layered: Go 3s / PG stmt 2.5s / lock 1.5s |
| Database | **PostgreSQL 17** | ACID, IDENTITY on partitioned, MERGE PARTITION |
| Backup | `pg_basebackup` daily + WAL archive continuous | Y1 không cần incremental |
| Migration | goose / Atlas (SQL-first) | Schema + function DDL together |
| Testing | pgTAP + Testcontainers Go | Unit test plpgsql trên real PG |
| Cache | Redis (rate-limit only, **không phải balance**) | Standard pattern |
| Streaming | Kafka (MSK serverless 3-broker) | Event emission qua outbox |
| **Outbox relay** | **Go polling worker** (Y1) | Đơn giản hơn Debezium; migrate khi > 500 TPS |
| DR | Active-passive cross-region (manual failover) | Cost balance Y1 |
| Observability | Prometheus + Grafana + Loki + OpenTelemetry | OSS, single dashboard |

### 11.1 PostgreSQL config (4c/16GB)

```ini
# Memory
shared_buffers = 4GB
effective_cache_size = 12GB
work_mem = 16MB
maintenance_work_mem = 512MB
wal_buffers = 64MB

# WAL & durability — KHÔNG tắt
wal_level = logical
synchronous_commit = on
fsync = on
max_wal_senders = 5
max_replication_slots = 5
checkpoint_timeout = 15min
max_wal_size = 4GB

# Connections (PgBouncer multiplex)
max_connections = 100

# Autovacuum aggressive cho hot tables
autovacuum_max_workers = 3
autovacuum_naptime = 10s
autovacuum_vacuum_scale_factor = 0.05
autovacuum_vacuum_cost_limit = 1500

# Timeouts (HLD §9 layering)
statement_timeout = 2500ms
lock_timeout = 1500ms
idle_in_transaction_session_timeout = 30s

# Planner
random_page_cost = 1.1
effective_io_concurrency = 200

# Logging
log_min_duration_statement = 500ms
log_checkpoints = on
log_lock_waits = on
```

Per-table:
```sql
ALTER TABLE WLT_ACCT SET (fillfactor = 80);
ALTER TABLE WLT_ACCT SET (autovacuum_vacuum_scale_factor = 0.02);
ALTER TABLE WLT_TRAN_HIST SET (autovacuum_vacuum_insert_scale_factor = 0.01);
```

### 11.2 PgBouncer config

```ini
[databases]
wallet = host=pg-primary port=5432 dbname=wallet

[pgbouncer]
pool_mode = transaction
max_client_conn = 500
default_pool_size = 50
reserve_pool_size = 10
reserve_pool_timeout = 5
server_idle_timeout = 600
max_prepared_statements = 200
```

---

## 12. Data Lifecycle — Y1 simplified

| Tier | Y1 retention | Mechanism |
|------|--------------|-----------|
| **Hot (PG primary)** | Tất cả data | Monthly partition manual; ~30–70 GB total Y1–Y2 |
| **Backup** | 30 days WAL + 90 days base backup + 12 months monthly snapshot | Daily `pg_basebackup` + continuous WAL archive to S3 |
| **DR replica** | Continuous (cross-region async) | Logical replication |
| ~~Warm tier~~ | — | **Defer** (DB chưa đủ lớn) |
| ~~Cold (Parquet)~~ | — | **Defer** (≥ Y2) |
| ~~Deep Archive~~ | — | **Defer** (≥ Y4) |

### 12.1 Backup matrix Y1

| Backup type | Frequency | Storage | Retention | Restore SLA |
|-------------|-----------|---------|-----------|-------------|
| WAL streaming sync | Continuous | Same-AZ standby | 30 days | Failover < 5 min |
| WAL streaming async | Continuous | Cross-region DR | Live | Failover < 30 min (manual) |
| WAL archive | Every 30s | S3 (Object Lock 30d) | 30 days | PITR within window |
| Full base backup | Daily 02:00 | S3 cross-region | 90 days | Full restore 1–2h |
| Monthly snapshot | 1st of month | S3 cross-region | 12 months | Long-term restore |
| Logical dump | Weekly | S3 cross-region | 12 months | Per-table restore |

### 12.2 Restore verification

- **Weekly** automated restore-test: pick latest base backup + replay WAL to a sandbox cluster, run schema + row-count + balance-sum invariant checks
- Failure pages on-call P1

---

## 13. Roadmap & Scale-up triggers

### 13.1 Phase roadmap

| Phase | Scope | Timeline |
|-------|-------|----------|
| **P0** | VND wallet + in-book transfer + Y1 tunings | M0–M3 |
| **P1** | Bank topup (1 partner) + withdraw (sync + WLT_WITHDRAW_TRACK) | M4–M6 |
| **P2** | Merchant payment + QR + multi-bank topup | M7–M9 |
| **P3** | KYC tier 2/3 + recurring + bill payment | M10–M12 |
| **P4** | Multi-currency, cross-border (Y2+, if licence) | Y2 |

### 13.2 Scale-up triggers — khi nào migrate từ bản này sang HLD gốc

| Signal | Threshold | Hành động |
|--------|-----------|-----------|
| Sustained TPS | > 50 | Upgrade PG: 8c/32GB; xem xét NVMe local |
| Peak TPS | > 150 | Tăng PG: io2 disk, scale app pods to 4+ |
| WLT_TRAN_HIST size | > 100 GB | Enable `pg_partman` auto-rolling, prepare warm tier |
| Outbox polling lag p99 | > 30 s | Migrate to Debezium CDC relay |
| 1 merchant TPS | > 30 | Enable sub-account sharding for merchant |
| Monthly limit query latency | > 5 ms p99 | Create `WLT_CUSTOMER_USAGE_MONTHLY` materialized counter |
| Active customers | > 5M | Review FM sharding (HLD §11 open question) |
| Total DB size | > 500 GB | Implement warm tier + Parquet cold export (HLD §9a) |
| EOD reconciliation complexity | Finance closes monthly with manual entries | Implement §9b accounting subsystem from HLD gốc |
| Multi-region active-active needed | Customer demands cross-region writes | Reassess — beyond HLD gốc scope |

→ Mỗi trigger là **một quyết định độc lập**. Không cần migrate tất cả cùng lúc.

---

## 14. Open Questions

### Assumptions
1. Payment-intermediary licence granted by SBV
2. ≥ 1 partner bank contract for TKĐBTT in place
3. eKYC provider contract in place
4. Y1 transaction volume < 50M tran/month (well within 20 TPS peak)

### Open
- [ ] **FM ownership** — which team owns FM tables? Maker-checker workflow? (blocking before P0)
- [ ] **Treasury contract** — explicit success/failure SLA + event/RPC schema (blocking before P1)
- [ ] **Tier-3 KYC limit** — per-contract limit storage table not in DDL
- [ ] **Monthly tier limit storage** — inline SUM acceptable at 20 TPS; pick materialized strategy before scale-up
- [ ] **Idempotency window** — `WLT_API_MESSAGE` 90-day hot vs reversal window (potentially 6–12 months)

---

## 15. Sizing Recommendation Summary

| Câu hỏi | Khuyến nghị |
|---------|-------------|
| **Hardware Y1?** | PG: 4 vCPU / 16 GB / 200 GB gp3 (5000 IOPS) + sync standby + DR replica |
| **Disk type?** | gp3 với provisioned IOPS = 5000 (đừng dùng default 3000) |
| **Connection pooling?** | PgBouncer transaction mode — bắt buộc kể cả ở 20 TPS |
| **Outbox relay?** | Go polling worker với `SKIP LOCKED` (defer Debezium đến > 500 TPS) |
| **Sharding?** | Không — `STANDALONE` cho tất cả wallets Y1 |
| **Data lifecycle?** | Hot + Backup only; defer warm/cold/archive |
| **Multi-region?** | Active-passive (sync same-AZ + async cross-region); manual failover OK |
| **Team size?** | 3.25 FTE (2 backend + 0.5 DBA + 0.5 SRE + 0.25 compliance) |
| **Infra cost?** | ~$1.700/tháng (~$20K/năm) |
| **Latency target Y1?** | p50 < 100 ms, p99 < 250 ms — dễ đạt với headroom |
| **Khi nào lo scale-up?** | Theo §13.2 triggers, không phải theo lịch cố định |

---

## 16. References

- `wallet_HLD.md` — comprehensive design for 2K/5K TPS, multi-tier lifecycle, sharding, Debezium
- `wallet_DLD.md` — table-level DDL (v1.6.6 — includes METADATA/CLIENT_INFO + WLT_CLIENT_AUDIT_LOG)
- `wallet_onboarding.md` — KYC tier rules + wallet opening flow
- `finance_transaction.md` — BRD + API spec for topup/withdraw/transfer/reversal/fee+VAT
- `wallet_seed.sql` — operational seed + bulk test-data generator
- `error_management.md` — error catalog + response envelope
- Decree 52/2024/NĐ-CP — non-cash payments
- Circular 23/2019/TT-NHNN — payment intermediary
- Decree 13/2023/NĐ-CP — Personal Data Protection

---

## Changelog

- **v1.0 (2026-05-28)**: Initial scoped HLD for 20 TPS Y1 launch. Derived from `wallet_HLD.md` v1.10 with the following deltas:
  - NFR retargeted to 20 TPS peak, 1–2M customers, p99 < 250 ms, RTO 30 min, 99.9% availability
  - Section 2 added: Sizing & Cost Recommendation (hardware, cost envelope, team sizing, latency expectations)
  - Outbox relay: polling worker (defer Debezium)
  - Sub-account sharding: deferred (no merchant > 30 TPS)
  - Data lifecycle: Hot + Backup only (defer warm/cold/archive)
  - Multi-region: active-passive with manual DR failover (defer active-active)
  - Tech stack §11.1 + §11.2: explicit PostgreSQL + PgBouncer config for 4c/16GB
  - §13.2 scale-up triggers: criteria for migrating to comprehensive HLD patterns
  - All correctness primitives preserved: outbox atomicity, withdraw tracking, audit log, encryption, PII §8.3
