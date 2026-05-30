# High-Level Design — Core Account E-Wallet System

**Version**: 1.1
**Date**: 2026-05-28
**Status**: Draft
**Author**: Core Wallet Team

**Changelog**
- v1.10 (2026-05-28): **Transaction metadata + client-info snapshot + client change-data audit** (DLD §2.5, §2.13). Two new JSONB columns on `WLT_TRAN_HIST`: `METADATA` (caller-supplied transaction context, ≤ 1 KB, P1-forbidden — channel/device/geo/risk/session) and `CLIENT_INFO` (SP-computed customer snapshot at posting time, ≤ 512 B, P2-only — kyc_tier/name_initials/residence/risk_level). New `WLT_CLIENT_AUDIT_LOG` table with a SECURITY DEFINER trigger captures every INSERT/UPDATE/DELETE on client tables (`WLT_CLIENT_KYC` now; FM_CLIENT* via FM-team coordination) with OLD/NEW JSONB + diff'd `CHANGED_FIELDS[]` + maker-checker fields. Apps set `SET LOCAL audit.actor/source/reason/...` GUCs per TX so the trigger attributes the change. **Posting and audit are decoupled**: the posting SP does not read the audit log on the hot path; investigators join `WLT_TRAN_HIST.POST_DATE` ↔ `WLT_CLIENT_AUDIT_LOG.CHANGED_AT` by time range to reconstruct "what changed about this customer between transactions X and Y". PII rules in §8.3 apply to the audit log unchanged.
- v1.9 (2026-05-28): **Transactional outbox + withdraw disbursement tracking** — close the two P0 gaps from the senior-SA review. Add the `WLT_OUTBOX` table (see DLD §2.11) so every posting SP writes the Kafka event row inside the same TX as `WLT_TRAN_HIST` — Kafka emission is now atomic with the ledger commit, no more silently-dropped events. Relay topology: Debezium CDC primary, Go polling worker with `SKIP LOCKED` as Y1 fallback. Add the `WLT_WITHDRAW_TRACK` table (DLD §2.12) with state machine `SUBMITTED → ACKED → DISBURSING → COMPLETED | FAILED → REVERSED`, keyed by `EXT_PAYOUT_REF`. Add `post_withdraw_reversal` SP (idempotent, refunds amount + fee + VAT) plus an SLA-timeout janitor that auto-reverses withdrawals stuck > 24h without a Treasury terminal state. The wallet owns the tracking + reversal SP; the mechanism by which the Treasury Service notifies the wallet of disbursement outcomes lives in the Treasury Service spec (out of scope).
- v1.8 (2026-05-28): Add **§9b Accounting Operations Subsystem** — EOD close & period locking, suspense/clearing GL framework, daily trial-balance materialisation with signed proof, e-invoice integration (Decree 123/2020 + Circular 78/2021), maker-checker manual journal entry workflow. Closes the top-5 finance/audit gaps identified in the 10-year SA review.
- v1.7.1 (2026-05-28): Add **§9a Data Lifecycle, Backup & Archive Strategy** — 5-year volume projection, four-tier model (Hot/Warm/Cold/Archive), per-table prune rules, partition lifecycle automation (`pg_partman` + `MERGE/SPLIT`), backup matrix (PG17 incremental basebackup + WAL streaming + cross-region DR), Parquet export to object storage with Object Lock (WORM), restore SLAs, legal-hold mechanism, cost projection.
- v1.7 (2026-05-28): Add **§8.3 PII Protection Standards** — data classification (P1–P4), storage/transit encryption, KMS key hierarchy, RBAC + masking, retention & crypto-shredding, audit log (`WLT_PII_ACCESS_LOG`), compliance mapping (Decree 13/2023, Cybersecurity Law 2018, Circular 23/2019, ISO 27001). NFR §7 references the new section; risk table §8.2 includes unauthorized PII access. Document is now in English.
- v1.6.1 (2026-05-28): **Tech stack: Go 1.23 + PostgreSQL plpgsql stored functions** (replacing Java + Spring Boot). All posting logic lives inside PG stored procedures; Go is a thin RPC client using `context.WithTimeout(3s)`. Timeout layering: Go 3s / PG statement 2.5s / PG lock 1.5s. Pool: pgxpool 50 max, 10 min conn.
- v1.6 (2026-05-28): Scope reduced to **internal sync transactions only**. NAPAS / partner bank / card 3DS removed from the system context — these integrations are split into a separate **Treasury Service** (out of scope, separate spec). Top-up is reframed as an internal s2s credit (Treasury → wallet); withdraw becomes a sync `DR wallet / CR internal nostro` with disbursement handoff via Kafka event. **Deferred locking pattern** applied throughout posting (Phase 1 no-lock validate → Phase 2 atomic UPDATE). Removed `WLT_MEMO_TRAN` and the `HOLD_AMT` column. State machine collapsed: PENDING/ACCEPTED/COMPLETED/EXPIRED removed.
- v1.5 (2026-05-28): OLTP database upgraded to **PostgreSQL 17**. Leverages: IDENTITY on partitioned tables, `ALTER TABLE MERGE/SPLIT PARTITION`, incremental base backup (better RPO), logical replication failover slots (path toward active-active DR).
- v1.4 (2026-05-28): OLTP database finalized as **PostgreSQL 16** (Oracle removed from the tech stack). Companion DLD updated to Postgres DDL/DML dialect.
- v1.3 (2026-05-28): Added Fee & VAT engine (transaction fee + VAT calculation, fee posted as separate leg, GL revenue + VAT payable).
- v1.2: Scope trimmed — removed FX, BIC/SWIFT, settlement instructions, org structure, reference codes, onboarding flow detail.
- v1.1: Refactored to two-tier FM + WLT.
- v1.0: Initial version.

---

## 1. Objectives & Scope

### 1.1 Business objectives
Build a **Core Wallet** system that manages e-wallet accounts and processes:
- **Top-up**: load funds from bank account / card / partner
- **Transfer**: wallet ↔ wallet, wallet → bank
- **Withdraw**: withdraw to a bank account
- **Payment**: pay to merchants
- **Fee & VAT**: compute transaction fees + VAT, post fee revenue and VAT payable
- **Reversal**: reverse/refund a transaction (including fee + VAT refund)

### 1.2 Technical objectives
- **Double-entry** posting, atomic (DR = CR always balanced)
- **Strong consistency** on wallet balances
- Clear segregation of **liability (customer wallet)** and **asset (TKĐBTT — segregated settlement account)** in the GL
- Real-time reconciliation with partner-bank statements (MT940 / API)
- Comply with Decree 52/2024 and Circular 23/2019 of the SBV (State Bank of Vietnam)
- Throughput target: **2,000 TPS** sustained, **5,000 TPS** peak
- Latency p99 < **300ms** for in-wallet transfer

### 1.3 Out of scope
- Physical card system
- Lending / credit / overdraft
- Term deposit products
- Crypto / securities exchange
- **External payment integration** (v1.6): NAPAS callback, partner banks (BIDV/VCB/...), card 3DS, partner wallets (MoMo/ZaloPay), MT940 reconciliation — **split into a separate Treasury Service spec**. The wallet ledger is responsible only for internal sync posting.

### 1.4 FM (Foundation Master) integration
- Use `FM_CLIENT` as the customer master (golden source) instead of maintaining clients inside WLT.
- Use `FM_GL_MAST` as the chart of accounts (single source of truth for the GL).
- Use `FM_NOS_VOS` as the master for the segregated settlement account (nostro).
- Use `FM_CURRENCY` for CCY configuration (decimal places, day basis); **no** multi-CCY exchange rates.

---

## 2. Stakeholders & Actors

| Stakeholder | Role | Primary interaction |
|-------------|------|---------------------|
| **End User** | Retail customer owning a wallet | Open wallet, top-up, transfer, payment via mobile app |
| **Merchant** | Corporate customer receiving payments | Merchant wallet, callback API, settlement |
| **Partner Bank** | Bank holding the TKĐBTT | Provides MT940 statement to Treasury Service (out of scope) |
| **NAPAS / Switch** | National payment switch | Routes top-up/withdraw via Treasury Service (out of scope) |
| **Treasury Service** | Bridge between external and the wallet ledger | Consumes `withdraw.posted` events to batch disbursements; calls `/topup` s2s after receiving external funds (out of scope, separate spec) |
| **SBV (State Bank of Vietnam)** | Regulator | Periodic reporting, audit |
| **Operations team** | Operations | Recon, dispute, helpdesk |
| **Finance team** | Accounting | GL recon, financial reporting |
| **Compliance/Risk** | Compliance | KYC, AML/CFT, monitoring |

---

## 3. System Context (v1.6 — internal-only scope)

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
   ┌──────────────┬───────────────┼─────────────────┬─────────────┐
   │              │               │                 │             │
┌──▼──┐      ┌────▼─────┐    ┌────▼─────┐     ┌────▼────┐   ┌────▼────┐
│Onbrd│      │ Posting  │    │ Account  │     │  Recon  │   │ Report  │
│ &   │      │  Engine  │    │  Mgmt    │     │  Engine │   │ Service │
│ KYC │      │          │    │          │     │         │   │         │
└──┬──┘      └────┬─────┘    └────┬─────┘     └────┬────┘   └────┬────┘
   │              │                │                │             │
   └──────────────┴────────┬───────┴────────────────┴─────────────┘
                           │
                ┌──────────▼──────────────────────────────┐
                │   Core Wallet Database (PostgreSQL 17)   │
                │   WLT_ACCT • WLT_TRAN_HIST • WLT_GL_BATCH   │
                │   WLT_RESTRAINTS • WLT_ACCT_BAL          │
                │   WLT_OUTBOX (transactional outbox) ★    │
                │   WLT_WITHDRAW_TRACK (disbursement st.)★ │
                └──────────────────────┬───────────────────┘
                                       │ WAL stream / SKIP LOCKED poll
                ┌──────────────────────▼───────────────────┐
                │  Outbox Relay (Debezium CDC primary;     │
                │   Go polling worker as Y1 fallback) ★    │
                │  Atomic guarantee: outbox row exists iff │
                │   WLT_TRAN_HIST row exists.              │
                └──────────────────────┬───────────────────┘
                                       │
                ┌──────────────────────▼───────────────────┐
                │  Streaming Bus (Kafka)                   │
                │  events: tran.posted, withdraw.posted,   │
                │          withdraw.reversed,              │
                │          restraint.added, ...            │
                └────────┬─────────────────────────────────┘
                         │
        ┌────────────────┼──────────────────────────────────┐
        │ Internal downstream (in scope)                     │
        │  • Notification • DW • Fraud monitoring            │
        │  • GL system • Statement gen                       │
        └────────────────┼──────────────────────────────────┘
                         │
        ┌────────────────▼──────────────────────────────────┐
        │ External boundary (OUT OF SCOPE — separate spec)   │
        │  • Treasury Service: consume withdraw.posted →     │
        │    batch NAPAS settlement → MT940 recon            │
        │  • Topup gateway: NAPAS/card/partner ingress →     │
        │    confirm to wallet via POST /topup (s2s)         │
        │  • SBV reporting: nightly export                   │
        └────────────────────────────────────────────────────┘
```

> **v1.6 (2026-05-28)**: scope reduced to **internal ledger only**. NAPAS / partner bank / card 3DS integration is split into a separate service. The wallet ledger communicates with the "external world" through two gates:
> - **Ingress (top-up)**: external gateway calls POST /topup s2s after confirming funds in the nostro
> - **Egress (withdraw)**: wallet ledger emits a `withdraw.posted` Kafka event via the outbox relay (atomic with the ledger commit); Treasury Service consumes it to batch disbursement
>
> **v1.9 (2026-05-28)**: the outbox + withdraw-tracking additions make the egress path fail-safe. Treasury notifies the wallet of disbursement outcomes (ack / completed / failed) via a mechanism defined in the Treasury Service spec; on the wallet side those notifications drive `mark_withdraw_*` / `post_withdraw_reversal` SPs. If Treasury goes silent for > 24h, the wallet auto-reverses via the SLA janitor — the customer is never debited without a settled or refunded outcome.

---

## 3a. Two-tier architecture — FM (Foundation Master) + WLT (Wallet)

Following the T24 model, the core wallet is split into **two data tiers**:

```
┌────────────────────────────────────────────────────────────────┐
│  TRANSACTIONAL TIER — WLT_*                                     │
│  (state, transactions, balances — changes continuously)         │
│                                                                  │
│  WLT_ACCT • WLT_ACCT_BAL • WLT_TRAN_HIST • WLT_GL_BATCH            │
│  WLT_RESTRAINTS • WLT_API_MESSAGE • WLT_CLIENT_KYC              │
│                          │                                       │
│                          │ references (FK)                       │
│                          ▼                                       │
├────────────────────────────────────────────────────────────────┤
│  MASTER DATA TIER — FM_*                                         │
│  (reference, slow-changing, shared across modules)               │
│                                                                  │
│  ┌─ Customer Master ──────────────────────────────────────────┐ │
│  │ FM_CLIENT (108 cols) • FM_CLIENT_INDVL • FM_CLIENT_CONTACT │ │
│  │ FM_CLIENT_IDENTIFIERS • FM_CLIENT_BANKS                    │ │
│  └────────────────────────────────────────────────────────────┘ │
│  ┌─ Chart of Accounts & Nostro ───────────────────────────────┐ │
│  │ FM_GL_MAST • FM_NOS_VOS                                    │ │
│  └────────────────────────────────────────────────────────────┘ │
│  ┌─ Currency Config ──────────────────────────────────────────┐ │
│  │ FM_CURRENCY (decimal places, day basis)                    │ │
│  └────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
```

### 3a.1 Tier separation principles

| Principle | FM (Master) | WLT (Transactional) |
|-----------|-------------|---------------------|
| **Rate of change** | Slow (hours/days) | Fast (seconds/real-time) |
| **Owner** | Centralized data team | Wallet product team |
| **Read pattern** | Cache-friendly, near-static | Hot path, low latency |
| **Write pattern** | Maker-checker, heavy audit | High TPS, idempotent |
| **Sharing** | Shared across wallet/loan/payment/treasury | Wallet-only |
| **Source of truth** | Single (golden source) | Append-only ledger |

### 3a.2 Why split FM and WLT?

1. **Avoid duplicate customer records**: one customer may hold a wallet + a loan account + an investment account — all share the same `FM_CLIENT.CLIENT_NO`.
2. **Uniform GL**: the chart of accounts (`FM_GL_MAST`) is the **single source of truth** for every module — wallet cannot define a GL that differs from lending.
3. **Compliance / SBV reporting**: SBV requires customer-level reporting → a single client master is required.
4. **Extensibility**: adding new products (loans, investments) does not require re-creating customer or GL data.

### 3a.3 How WLT references FM

```
WLT_ACCT.CLIENT_NO         ──FK──▶ FM_CLIENT.CLIENT_NO
WLT_ACCT.CCY               ──FK──▶ FM_CURRENCY.CCY
WLT_ACCT_TYPE.GL_CODE      ──FK──▶ FM_GL_MAST.GL_CODE
WLT_NOSTRO_LINK.NOS_VOS_NO ──FK──▶ FM_NOS_VOS.NOS_VOS_NO
WLT_GL_BATCH.GL_CODE          ──FK──▶ FM_GL_MAST.GL_CODE
WLT_CLIENT_KYC.CLIENT_NO   ──FK──▶ FM_CLIENT.CLIENT_NO
```

> **Important**: WLT **never** modifies FM. All FM changes (edit GL, add nostro, change CCY config) go through a separate data-governance flow with maker-checker.

---

## 4. Logical Architecture — 9 core modules

| # | Module | Tier | Responsibility | T24 equivalent |
|---|--------|------|----------------|----------------|
| 1 | **API Gateway** | – | Accept requests, auth, throttle, idempotency check | OFS layer |
| 2 | **Foundation Master (FM)** | FM | Customer, GL chart, nostro, CCY config | Foundation module |
| 3 | **Account Management** | WLT | Wallet CRUD, status, limit, restraint | Account module |
| 4 | **Posting Engine** | WLT | 7-step posting pipeline, generate accounting entries | Transaction module |
| 5 | **Fee & VAT Engine** | WLT | Compute fee (fixed/percent/tier), compute VAT, generate fee + VAT legs into the posting | Service charge (RB_SERV_CHARGE) |
| 6 | **Ledger / GL Feed** | WLT→FM | Push `WLT_GL_BATCH` to the GL via `FM_GL_MAST` | Accounting module |
| 7 | **Reconciliation** | WLT+FM | Reconcile nostro (`FM_NOS_VOS`) vs ledger, break detection | Recon module |
| 8 | **Statement / Reporting** | WLT+FM | Customer statements, SBV reports, DW feed, **VAT report for the tax authority** | Statement module |
| 9 | **Notification** | – | Push, SMS, email per event | Channel adapter |

---

## 5. Data Architecture (high level)

### 5.1 Data layering (post-refactor)

```
┌──────────────────────────────────────────────────────────────┐
│ WLT TIER (Transactional — operational)                        │
├──────────────────────────────────────────────────────────────┤
│  Wallet & KYC                                                 │
│    WLT_ACCT, WLT_ACCT_TYPE, WLT_ACCT_BAL, WLT_CLIENT_KYC     │
│  Transaction & Fee/VAT config                                  │
│    WLT_TRAN_DEF (with fee/VAT cols), WLT_TRAN_HIST, WLT_GL_BATCH  │
│  Control                                                       │
│    WLT_RESTRAINTS, WLT_API_MESSAGE, WLT_API_TRACE             │
│    WLT_STMT_HEADER, WLT_STMT_DETAIL, WLT_OLTP_AUDIT          │
│  Linkages (WLT ↔ FM)                                          │
│    WLT_NOSTRO_LINK (link wallet GL ↔ FM_NOS_VOS)             │
│    WLT_NOSTRO_BAL  (daily snapshot)                          │
└──────────────────────────────────────────────────────────────┘
                          │
                          │ FOREIGN KEY references
                          ▼
┌──────────────────────────────────────────────────────────────┐
│ FM TIER (Foundation Master — golden source, shared)           │
├──────────────────────────────────────────────────────────────┤
│  Customer                                                      │
│    FM_CLIENT (108c), FM_CLIENT_INDVL, FM_CLIENT_IDENTIFIERS  │
│    FM_CLIENT_CONTACT, FM_CLIENT_BANKS                         │
│  Chart of Accounts                                             │
│    FM_GL_MAST (asset/liability/income/expense classification) │
│  Nostro / Vostro                                               │
│    FM_NOS_VOS (TKĐBTT master)                                 │
│  Currency                                                      │
│    FM_CURRENCY (decimal places, day basis)                   │
└──────────────────────────────────────────────────────────────┘
```

### 5.2 Data design principles
1. **Single source of truth**:
   - Wallet balance: `WLT_ACCT.ACTUAL_BAL`
   - Customer: `FM_CLIENT.CLIENT_NO`
   - GL chart: `FM_GL_MAST.GL_CODE`
   - Nostro: `FM_NOS_VOS.NOS_VOS_NO`
2. **Append-only**: `WLT_TRAN_HIST` is never UPDATEd, only INSERTed (a reversal is a new row).
3. **Idempotent**: every request carries a unique `REFERENCE` → check before posting.
4. **Atomic**: one business transaction = one DB transaction (including all legs + balance update).
5. **Auditability**: every change has a row in `WLT_OLTP_AUDIT` + `WLT_API_TRACE`; FM uses `FM_AUDIT_LOG`.
6. **Time-aware**: distinguish `TRAN_DATE` (transaction date), `EFFECT_DATE` (effective date), `POST_DATE` (posting date), `VALUE_DATE` (value date).
7. **FM is read-only from WLT**: WLT only SELECTs from FM, never UPDATEs/DELETEs.
8. **Point-in-time customer snapshot** (v1.10): each `WLT_TRAN_HIST` row carries a `CLIENT_INFO` JSONB populated by the posting SP from FM_CLIENT + WLT_CLIENT_KYC. Combined with `WLT_CLIENT_AUDIT_LOG` (every change to client data, captured by trigger), investigators can reconstruct what the customer looked like at any prior posting moment without depending on the current FM state. See DLD §2.5 + §2.13.
9. **Open metadata bag** (v1.10): each `WLT_TRAN_HIST` row carries a `METADATA` JSONB for caller-supplied transaction context (channel, device, geo, risk score, session) — bounded ≤ 1 KB, P1-forbidden. Lets fraud/analytics queries enrich transactions without schema changes for every new attribute.

---

## 6. Main business flows (high level)

### 6.1 Top-up (internal credit from Treasury Service)

```
[External flow — OUT OF SCOPE]
Customer ⇆ Bank/NAPAS/Card/Partner → Treasury Service confirms funds in the real nostro

[Wallet ledger — IN SCOPE, sync atomic]
Treasury Service → POST /v1/transactions/topup (s2s auth)
                    → Posting Engine
                       ├─► Phase 1: validate (no lock) — status, tier, CR-restraint, limit
                       ├─► Phase 2: atomic UPDATE WLT_ACCT (+amount, VERSION++)
                       │      └─► INSERT WLT_TRAN_HIST + WLT_GL_BATCH (DR nostro / CR wallet)
                       └─► COMMIT → emit "topup.posted" Kafka → 200 POSTED
```

### 6.2 Wallet → wallet transfer (in-book)

```
User A → App → API Gateway → Posting Engine (deferred locking)
                              ├─► Phase 1: SELECT 2 wallets + def + restraint (no lock)
                              ├─► Phase 2:
                              │   ├─► INSERT WLT_API_MESSAGE (idempotency gate)
                              │   ├─► UPDATE WLT_ACCT × 2 ordered by INTERNAL_KEY ASC
                              │   │      (atomic fund check + VERSION in WHERE)
                              │   ├─► INSERT WLT_TRAN_HIST × 3 (DR A, CR B, FEETRF A)
                              │   ├─► INSERT WLT_GL_BATCH × 5 (DR/CR core + 3 fee/VAT legs)
                              │   ├─► UPSERT WLT_ACCT_BAL × 2
                              │   └─► COMMIT
                              └─► emit "transfer.posted" → 200 POSTED
```

### 6.3 Withdraw (sync internal — handoff to Treasury, with disbursement tracking)

```
[Wallet ledger — IN SCOPE]
User → App → POST /withdraw → Posting Engine (deferred locking)
              ├─► Phase 1: validate (no lock) — status, tier 2, DR-restraint, fund (incl fee+VAT)
              ├─► Phase 2 (atomic, single TX):
              │   ├─► UPDATE WLT_ACCT (-amount-fee, VERSION++)
              │   ├─► INSERT WLT_TRAN_HIST × 2 (WDRAW + FEEWD)
              │   ├─► INSERT WLT_GL_BATCH × 5 (DR wallet / CR internal nostro + fee/VAT)
              │   ├─► INSERT WLT_WITHDRAW_TRACK(STATUS='SUBMITTED', EXT_PAYOUT_REF,
              │   │           ACK_DEADLINE=NOW()+60s, FINAL_DEADLINE=NOW()+24h)
              │   ├─► INSERT WLT_OUTBOX(event='wallet.withdraw.posted.v1', ...)
              │   └─► COMMIT → 200 POSTED immediately (sync)
              │
              ▼ (async, ~<1s)
        Outbox relay (Debezium / polling worker) → Kafka topic `wallet.withdrawals`

[External flow — OUT OF SCOPE]
Treasury Service consumes `withdraw.posted` → batch NAPAS payout → MT940 T+1 nostro recon

[Wallet ledger — IN SCOPE, async receipts]
Treasury notification (mechanism per Treasury spec) → calls one of:
  ├─► mark_withdraw_acked(ext_ref, batch_id)        → STATUS='ACKED'
  ├─► mark_withdraw_disbursing(ext_ref)             → STATUS='DISBURSING'
  ├─► mark_withdraw_completed(ext_ref, napas_ref)   → STATUS='COMPLETED' (terminal)
  └─► post_withdraw_reversal(ext_ref, fail_code,    → STATUS='REVERSED' (terminal)
        fail_reason, 'TREASURY_FAILED')                + credit-back posted to customer
                                                        + RVWD + RVFEE legs + WLT_GL_BATCH reversed
                                                        + WLT_OUTBOX(event='wallet.withdraw.reversed.v1')

[SLA safety net — IN SCOPE]
pg_cron janitor (every 60s):
  ├─► STATUS='SUBMITTED' AND ACK_DEADLINE<NOW()      → alert ops (P2)
  └─► STATUS IN ('ACKED','DISBURSING')               → auto-call post_withdraw_reversal(
       AND FINAL_DEADLINE<NOW()                          ext_ref, 'SLA_TIMEOUT', ..., 'SLA_TIMEOUT')
                                                       → customer is never debited without a
                                                          settled or refunded outcome
```

**Customer-facing semantics**:
- Balance reflects `WLT_ACCT.ACTUAL_BAL` immediately on POST success (the wallet is the canonical view).
- Transaction history shows the withdraw with a `settlement_status` derived from `WLT_WITHDRAW_TRACK.STATUS` — the app can render "Initiated" / "Processing" / "Completed" / "Refunded" without the ledger ever lying about the balance.
- Two notifications per withdraw: "initiated" at submission, "completed" or "failed & refunded" at terminal state.

**Idempotency contract**:
- `EXT_PAYOUT_REF` is the wallet-issued single correlation key across every wallet ↔ Treasury exchange and across every state-transition SP.
- `post_withdraw_reversal` is idempotent on `EXT_PAYOUT_REF` — duplicate calls return the existing reversal key with `was_already_reversed=TRUE`, no double-credit possible.

### 6.4 Fee & VAT posting

**Fee + VAT config lives in `WLT_TRAN_DEF`** (extra columns, no separate table):
each `TRAN_TYPE` (e.g. `TRFOUT`, `WDRAW` — max 6 characters) carries `FEE_TYPE` (FIXED/PERCENT/NONE), `FEE_AMT`, `FEE_RATE`, `FEE_MIN`, `FEE_MAX`, `VAT_RATE`, `FEE_GL_CODE`, `VAT_GL_CODE`. The engine reads it once to post both the main transaction and the fee leg.

For each transaction that has a fee, the posting engine generates **3 extra legs** under the same `TFR_INTERNAL_KEY`:

```
Original transaction (transfer 1M, FEE_TYPE='FIXED', FEE_AMT=5,500 gross, VAT_RATE=0.10):
   Leg 1: DR Wallet A   1,000,000     (transfer amount)
   Leg 2: CR Wallet B   1,000,000     (transfer amount)
   Leg 3: DR Wallet A       5,500     (fee + VAT charge — total customer pays)
   Leg 4: CR GL 401.01      5,000     (Fee revenue — net of VAT)
   Leg 5: CR GL 203.01        500     (VAT output payable — paid to the tax authority)

Customer sees: wallet A −1,005,500; wallet B +1,000,000.
```

**Fee calculation engine** (read from `WLT_TRAN_DEF`):
1. Look up the `WLT_TRAN_DEF[TRAN_TYPE]` row to retrieve fee config.
2. Compute gross fee (VAT-inclusive):
   - `FEE_TYPE='FIXED'` → `fee_gross = FEE_AMT`
   - `FEE_TYPE='PERCENT'` → `fee_gross = TRAN_AMT × FEE_RATE`, clamped to `[FEE_MIN, FEE_MAX]`
   - `FEE_TYPE='NONE'` → skip
3. Split VAT: `vat_amt = fee_gross × VAT_RATE / (1 + VAT_RATE)`; `fee_net = fee_gross − vat_amt`.
4. Generate DR wallet + CR `FEE_GL_CODE` + CR `VAT_GL_CODE` legs into `WLT_TRAN_HIST` (TRAN_TYPE = `FEE_TRAN_TYPE`, e.g. `FEETRF`) + `WLT_GL_BATCH`.
5. VAT reporting queries directly from `WLT_TRAN_HIST` joined with `WLT_TRAN_DEF` for a given date range.

**Periodic VAT remittance** (end of month): DR `GL 203.01 VAT payable` / CR `GL operational nostro` — transferring funds to the tax authority.

### 6.5 Reversal / Refund

- A reversal **does not UPDATE** the original row.
- Generate 2 new rows (DR↔CR flipped), `REVERSAL_TRAN_TYPE` links back to the original row via the original transaction's `TFR_INTERNAL_KEY` + `REVERSAL_DATE`.
- If the original transaction collected a fee + VAT → the reversal must **refund both the fee and the VAT** (3 reversed legs).

---

## 7. Non-Functional Requirements

| NFR | Target |
|-----|--------|
| **Availability** | 99.95% (≤ 4.4h downtime/year) |
| **Throughput** | 2,000 TPS sustained, 5,000 TPS peak |
| **Latency** | p50 < 100ms, p99 < 300ms (in-book transfer) |
| **Recovery** | RTO ≤ 15 min, RPO ≤ 1 min (DR site active-passive; RPO can drop to ~30s with PG17 hourly incremental base backup) |
| **Data retention** | 18 months online, 10 years archive |
| **Encryption** | TLS 1.3 in-transit, AES-256 at-rest, column-level for PII (see §8.3) |
| **PII protection** | Data classification (P1–P4), KMS-backed column encryption, audit log on every P1 read, 72h breach SLA (see §8.3) |
| **Audit** | 100% of transactions are traceable; immutable log (WORM) |
| **Compliance** | Decree 52/2024, Circular 23/2019, PCI-DSS (if cards are accepted), ISO 27001 |

---

## 8. Compliance & Risk

### 8.1 Vietnamese legal framework
- **TKĐBTT (segregated settlement account)**: mandatory segregation, never mixed with operating funds.
  - Master record: `FM_NOS_VOS` with `ACCT_TYPE='TKDBTT'`
  - GL: `FM_GL_MAST` with `GL_TYPE='A'` (asset), `BSPL_TYPE='B'` (balance sheet)
- **Mandatory equation**: `Σ TKĐBTT (FM_NOS_VOS) ≥ Σ customer wallet balances (WLT_ACCT)` at all times.
- **VAT (Value Added Tax)**:
  - Payment-intermediary services are subject to 10% VAT under the VAT Law
  - The tariff published to customers is **gross (VAT-inclusive)**
  - VAT collected on behalf → posted to `GL 203.01 VAT output payable` (liability), remitted to the tax authority monthly
  - Periodic VAT report: `SUM(WLT_TRAN_HIST.TRAN_AMT)` for VAT tran types (lookup `WLT_TRAN_DEF` to filter) by month → form 01/GTGT
- **KYC tier** (stored in `WLT_CLIENT_KYC`, customer master in `FM_CLIENT`):
  - Tier 1: phone + basic identification → limit 20M / month
  - Tier 2: + CCCD (citizen ID) / eKYC (verified via `FM_CLIENT_IDENTIFIERS`) → limit 100M / month
  - Tier 3: + biometric verification + linked bank (`FM_CLIENT_BANKS`) → limit per contract
- **AML/CFT**: monitor anomalous transactions, report CTR/STR to SBV.

### 8.2 Risks & mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Double posting due to retry | Balance drift | Idempotency key + unique index |
| Race condition on balance | Negative balance | `SELECT FOR UPDATE` ordered locking |
| TKĐBTT < total wallet balance | SBV violation | Real-time recon + alert |
| MT940 vs internal ledger mismatch | Bank discrepancy | Daily recon job + break workflow |
| Top-up fraud from stolen cards | Financial loss | 3DS + velocity check + T+1 hold |
| Disaster (primary DC loss) | Downtime | DR site, sync replication, auto-failover |
| Unauthorized PII access / leak | Regulatory penalty + reputational damage | §8.3 controls — column encryption, RBAC, audit log |
| Kafka event dropped between PG commit and producer ack | Treasury / notification / fraud miss the event silently → customer debited but never disbursed | **v1.9**: transactional outbox `WLT_OUTBOX` (DLD §2.11). Outbox row written inside the same TX as `WLT_TRAN_HIST`; Debezium/polling relay ships at-least-once; consumers idempotent on `EVENT_UUID` |
| Withdraw posted but never settled by Treasury (NAPAS reject / Treasury silent) | Customer debited without payout, regulatory exposure under Circular 23/2019 | **v1.9**: `WLT_WITHDRAW_TRACK` disbursement state machine + `post_withdraw_reversal` SP idempotent on `EXT_PAYOUT_REF` + pg_cron SLA janitor auto-reverses at `FINAL_DEADLINE` (default 24h) |

### 8.3 PII Protection Standards

Personal data handling follows Vietnam's **Decree 13/2023/NĐ-CP** (Personal Data Protection) and the **Cybersecurity Law 2018**, with ISO 27001 controls as the implementation baseline.

#### 8.3.1 Data classification

Every column in WLT and FM tables is tagged with one of four tiers. Classification drives the storage, masking and access controls below.

| Tier | Definition | Examples in this system |
|------|-----------|-------------------------|
| **P1 — Direct identifiers** | Identify an individual on their own | `FM_CLIENT_IDENTIFIERS.GLOBAL_ID` (CCCD, passport), `WLT_CLIENT_KYC.PHONE_NO`, `WLT_CLIENT_KYC.EMAIL`, `FM_CLIENT.CLIENT_NAME`, `FM_CLIENT_BANKS.ACCT_NO_ENC` |
| **P2 — Quasi-identifiers** | Identifying when combined with other data | `FM_CLIENT_INDVL.BIRTH_DATE`, `FM_CLIENT_CONTACT.ADDR_*`, device fingerprint, IP, `TERMINAL_ID` |
| **P3 — Sensitive financial** | Financial activity bound to identity | `WLT_ACCT.ACTUAL_BAL`, `WLT_TRAN_HIST.*`, `WLT_STMT_DETAIL.*`, `WLT_GL_BATCH.*` |
| **P4 — Authentication secrets** | Credentials and crypto material | API client secrets, signing keys, OTP, session tokens, eKYC face-match templates |

> Wallet `ACCT_NO` is treated as **P2** — it's not directly an identity but uniquely maps to one customer, and is exposed to counterparties on transfers.

#### 8.3.2 Storage protections

| Layer | Mechanism | Applies to |
|-------|----------|-----------|
| Disk-level encryption | LUKS / cloud-managed KMS (e.g. EBS gp3 + KMS) | All PG data + WAL volumes |
| Cluster-level TDE | PG storage encryption with externally managed key | OLTP and DR replicas |
| Column-level encryption | `pgcrypto` `pgp_sym_encrypt`, DEK held in KMS, decrypted only inside the SP context | All **P1** columns + P4 secrets |
| Hashing (one-way) | Argon2id (passwords/PIN), HMAC-SHA256 (OTP), salted | P4 credentials — never reversibly stored |
| Tokenization | Format-preserving token replacing raw PAN | Activated if/when card data is ever stored (currently out of scope) |

**Encryption-key hierarchy**:
```
KMS (HSM-backed master key, per-environment)
   └─► KEK (key-encryption key, rotated every 3 years)
         └─► DEK (data-encryption key, rotated annually)
               └─► Column ciphertext in PG
```

#### 8.3.3 Transit protections

- **TLS 1.3** mandatory on every external endpoint; lower versions rejected at the gateway.
- **mTLS** between internal services (API gateway ↔ posting service ↔ PG): client cert pinned in the service mesh.
- **PG connections** require `sslmode=verify-full`; cert auto-rotated by cert-manager / cloud-managed CA.
- Cert lifetime ≤ 90 days; pin rotation through service mesh, never application config.

#### 8.3.4 Access control

| Principle | Implementation |
|-----------|----------------|
| **Least privilege** | Three DB roles: `wallet_app` (no P1 read; goes through masking views), `wallet_pii_ro` (P1 read with full audit), `wallet_admin` (key rotation, schema changes — break-glass only) |
| **No direct PG access in prod** | Engineers reach prod via PAM bastion + session recording; ad-hoc SQL requires ticket + 2-person approval |
| **MFA + JIT** | Production elevated access requires MFA and a just-in-time grant ≤ 4 hours, auto-expiring |
| **App-level scopes** | API caller must present an OAuth scope `pii:read` to receive unmasked P1 fields; default response is masked |
| **Cross-tenant guard** | Service accounts limited to their own client scope via row-level security policies on `FM_CLIENT`/`WLT_ACCT` |

#### 8.3.5 Masking patterns (default API response)

| Field | Storage | Default response | Unmasked condition |
|-------|---------|------------------|---------------------|
| CCCD / passport | Encrypted | `***-***-1234` (last 4) | Scope `pii:read` + customer == caller subject, or compliance role |
| Phone | Encrypted | `09xxxxx789` | Same as above |
| Email | Encrypted | `j****@gmail.com` | Same as above |
| Full name | Encrypted | First name only | Same as above |
| Wallet `ACCT_NO` | Plaintext (operational) | `9701********0099` (mask middle 8) | Owner or compliance |
| Bank `ACCT_NO` (linked bank) | Encrypted | `****1234` | Owner only, withdrawal confirmation screens |
| Balance, history | Plaintext within tenant | Full to owner; masked summary to merchant counterparty | Per business rule |

Masking is enforced by a thin view layer (`v_client_masked`, `v_kyc_masked`) and by an envelope filter in the API gateway; bypassing it requires the explicit scope above and is logged.

#### 8.3.6 Retention & deletion

- **Active customer**: P1 retained for the lifetime of the relationship.
- **Closed wallet**: P1 data retained 5 years post-closure (Decree 13/2023 + Circular 23/2019 record-keeping), then **crypto-shredded** by destroying the row's DEK while preserving the encrypted blob for forensic chain-of-custody.
- **Right-to-erasure request**: Compliance review within 30 days; if granted, `FM_CLIENT` row is tombstoned (preserves transactional integrity), P1 columns NULL'd, audit row inserted in `FM_AUDIT_LOG`.
- **Transactional history** (P3): retained per banking record-keeping rule (10 years online + archive); erasure does **not** apply to anti-money-laundering records.
- **Non-prod environments**: synthetic data only (see `wallet_seed.sql` bulk generator). Production PII must **never** be copied to dev/staging/CI; mirroring tools must use the masked views.

#### 8.3.7 Audit & monitoring

- Every P1 column read is appended to `WLT_PII_ACCESS_LOG` (immutable, WORM): caller identity, query fingerprint, row count, timestamp, source IP.
- **Every change** to a client-identity column (INSERT/UPDATE/DELETE on `WLT_CLIENT_KYC` and FM_CLIENT*) is captured by the `fn_audit_client_change` trigger into `WLT_CLIENT_AUDIT_LOG` with OLD/NEW JSONB, diff'd `CHANGED_FIELDS[]`, actor, source (`OPS_UI`/`API`/`EKYC`/`SYS_BATCH`/`COMPLIANCE`), reason, and maker-checker fields. See DLD §2.13. The audit table is SECURITY DEFINER write-only — even DBAs cannot UPDATE/DELETE its rows in production.
- **Alerts**:
  - > 100 P1 reads/hour per service account → P2 incident
  - Any P1 read by `wallet_admin` role → P3 incident (admin should never read PII operationally)
  - Failed decrypt rate > 0.1% → P2 (possible KMS misconfiguration or key revocation)
  - Client-info change with `CHANGE_SOURCE='SP_BACKFILL'` (the default when the app forgot to set audit GUCs) → P2 (missing middleware attribution)
  - KYC tier downgrade (`old_tier > new_tier`) without an `APPROVAL_REF` → P1 (compliance bypass attempt)
- Quarterly access review by Compliance; annual penetration test scoped on PII paths.
- Breach notification SLA: **72 hours** to MPS (Ministry of Public Security) and affected data subjects, per Decree 13/2023 Article 23.

#### 8.3.8 Compliance mapping

| Standard | Coverage in this system |
|----------|--------------------------|
| **Decree 13/2023/NĐ-CP** (VN Personal Data Protection) | Classification §8.3.1, consent capture at onboarding, breach notification SLA, retention §8.3.6, DPO designation |
| **Cybersecurity Law 2018** | Data localization (PG cluster on Vietnamese soil), incident reporting to A05/MPS |
| **Circular 23/2019/TT-NHNN** | Customer data handling for payment intermediaries |
| **ISO 27001** Annex A.8 / A.9 / A.10 / A.18 | Asset management, access control, cryptography, compliance |
| **PCI-DSS** | Activated only if/when card PAN is stored (currently out of scope — top-up cards handled by Treasury Service) |
| **GDPR** | Not in scope (no EU data subjects) |

#### 8.3.9 Implementation responsibilities

| Activity | Owner | Cadence |
|----------|-------|---------|
| Column classification review | Data team + Compliance | Per schema change + annual |
| KEK rotation | Platform / Security | Every 3 years |
| DEK rotation | Platform | Annually + on-demand on suspected exposure |
| Access review | Compliance | Quarterly |
| Penetration test (PII paths) | External vendor | Annually |
| Breach drill | Security + Ops + Legal | Semi-annually |
| DPO report to MPS | Compliance | As required by Decree 13/2023 |

---

## 9. Recommended Tech Stack

| Layer | Choice | Rationale |
|-------|--------|-----------|
| API Gateway | Kong / APISIX | Mature, plugin-rich |
| Service runtime | **Go 1.23 + chi/fiber** | Goroutine concurrency, low memory footprint, fast cold start. Thin RPC client calling PG stored procedures |
| Posting logic | **PostgreSQL 17 plpgsql functions** | Phase 1 validate + Phase 2 commit in a single SP call; one round-trip; lock window 0.5–1ms; in-process atomic guarantee |
| DB driver | **pgx/v5 + pgxpool** | Native PG protocol, high performance, supports PG17 features. No ORM on the hot path |
| Caller timeout | **`context.WithTimeout(3s)`** | Hard client-side ceiling; layered with PG `statement_timeout=2.5s`, `lock_timeout=1.5s` |
| Database (OLTP) | PostgreSQL 17 | Strong ACID; IDENTITY on partitioned tables; native `MERGE/SPLIT PARTITION`; incremental base backup; logical replication failover slots; B-tree multi-value scan |
| Partition management | pg_partman + native `ALTER TABLE MERGE/SPLIT PARTITION` | Auto-create monthly partitions for WLT_TRAN_HIST, WLT_ACCT_BAL; merge to yearly for cold storage |
| Backup | `pg_basebackup --incremental` (PG17) | RPO < 1 minute is feasible with hourly incremental + weekly full |
| Cross-region DR | Logical replication with failover slots (PG17) | Slots survive primary failover → path toward active-active rather than only active-passive |
| Migration | **goose / Atlas** | SQL-first migrations for both schema and function DDL |
| Testing | **pgTAP + Testcontainers Go** | Unit test plpgsql functions on a real PG instance |
| Cache | Redis Cluster | Idempotency lookup, rate-limit counters (not used for balance) |
| Streaming | Kafka | Event emission (`tran.posted`, `withdraw.posted`, …) for downstream Treasury Service, DW, notifications |
| Search/Analytics | OpenSearch | Transaction search, BI |
| DR | Active-passive cross-region | Cost balance |
| Observability | Prometheus + Grafana + Loki + Tempo + **OpenTelemetry Go SDK** | OSS, end-to-end tracing; Go integrates naturally with otel |

> **v1.6 tech stack rationale**: switched from Java to Go because the posting logic lives entirely in PG plpgsql, so the service side is just a thin RPC + HTTP layer. Go's goroutine model fits concurrent request handling well, with a lighter footprint than the JVM. Complex logic (validate, fee, restraint, fund check) lives inside the PG SP → the application code is simple and does not need Java's heavy OOP.

---

## 9a. Data Lifecycle, Backup & Archive Strategy (5-Year Horizon)

This section defines how operational data flows out of the OLTP primary as it ages, how it is backed up for recovery, and how long-term records are archived to satisfy the 10-year banking retention requirement. The strategy is built around four tiers and a per-table policy.

### 9a.1 5-Year Volume Projection

Assumptions: launch in Y1 with Year-1 volume from §11 Assumptions (50M tran/month), 50% YoY growth, ~5 GL legs per transaction (Fee + VAT model), ~1.05 wallets per active customer.

| Year | Customers (active) | Tran/month | Tran/year | `WLT_TRAN_HIST` rows added | `WLT_GL_BATCH` rows added | Daily balance snapshots |
|------|--------------------|-----------|-----------|----------------------------|------------------------|--------------------------|
| Y1 | 3M | 50M | 600M | 1.8B (×3 legs avg) | 3B | 1.1B |
| Y2 | 5M | 75M | 900M | 2.7B | 4.5B | 1.8B |
| Y3 | 7M | 110M | 1.32B | 4.0B | 6.6B | 2.6B |
| Y4 | 10M | 165M | 2.0B | 6.0B | 10.0B | 3.7B |
| Y5 | 14M | 250M | 3.0B | 9.0B | 15.0B | 5.1B |
| **5Y cumulative** | – | – | **7.8B** | **23.5B** | **39.1B** | **14.3B** |

Per-row storage (post LZ4 compression on `WLT_API_MESSAGE.TEXT` columns, dense fixed-width on `WLT_TRAN_HIST`):

| Table | Avg row bytes (data+index) | 5Y total |
|-------|---------------------------|----------|
| `WLT_TRAN_HIST` | ~280 B | ~6.6 TB |
| `WLT_GL_BATCH` | ~110 B | ~4.3 TB |
| `WLT_ACCT_BAL` | ~90 B | ~1.3 TB |
| `WLT_API_MESSAGE` (payload ~600B LZ4'd) | ~700 B | ~5.5 TB |
| `WLT_PII_ACCESS_LOG`, `WLT_OLTP_AUDIT`, `WLT_SWEEP_LOG` | mixed | ~1.5 TB |
| **OLTP total if everything stays hot** | – | **~19 TB** |

A single PG17 primary can technically hold 19 TB, but at that size autovacuum churn, p99 latency, backup duration and partition catalog all degrade. **The plan keeps the hot primary ≤ 3 TB** by pruning Y3+ data into cheaper tiers.

### 9a.2 Four-Tier Lifecycle Model

```
                 ┌──────────────────────────────────────┐
HOT     0–13 mo  │  PG17 primary + standby              │   read/write, p99 < 10ms
                 │  All current-period partitions       │   ~3 TB cap
                 └──────────────┬───────────────────────┘
                                │ monthly: MERGE old months into yearly partition
                                ▼
                 ┌──────────────────────────────────────┐
WARM    13–36 mo │  PG17 cold replica (same cluster,    │   read-only, p99 < 1s
                 │   different tablespace on cheaper    │   ~6 TB
                 │   storage), partitions detached      │
                 │   from primary write path            │
                 └──────────────┬───────────────────────┘
                                │ quarterly: pg_dump + Parquet export, then DETACH+DROP
                                ▼
                 ┌──────────────────────────────────────┐
COLD    3–7 yr   │  Object storage (S3-compatible),     │   read on demand, retrieval < 60s
                 │   Parquet w/ ZSTD-19, partitioned by │   ~$5/TB/mo (Standard-IA)
                 │   month + acct_hash. Queryable via   │
                 │   Trino/Athena/DuckDB                │
                 └──────────────┬───────────────────────┘
                                │ S3 Lifecycle Rule: transition after 4 years
                                ▼
                 ┌──────────────────────────────────────┐
ARCHIVE 7–10+ yr │  Object storage Deep Archive tier    │   retrieve in 12–48h
                 │   (Glacier Deep Archive / Azure       │   ~$1/TB/mo
                 │   Archive). Object Lock (WORM) enabled│   immutable for compliance
                 └──────────────────────────────────────┘
```

Tier boundaries are configurable per table (next section). The 13-month hot window covers month-end + Q4 close + annual close + comparable-period reporting without going to warm.

### 9a.3 Per-Table Prune Policy

| Table | Hot (OLTP primary) | Warm (cold replica / detached) | Cold (object storage) | Archive | Notes |
|-------|--------------------|-------------------------------|----------------------|---------|-------|
| `WLT_TRAN_HIST` | 13 months | months 14–36 | year 4–7 in Parquet | year 8–10 Deep Archive | Drives most volume; partition by month + hash 32 |
| `WLT_GL_BATCH` | 13 months | months 14–24 | year 3–7 | year 8–10 | Once posted to GL and reconciled (T+1), only kept for audit |
| `WLT_ACCT_BAL` | 13 months daily | months 14–24 daily | year 3+ keep only month-end snapshot | – | Daily granularity not needed beyond 2 years; collapse to monthly |
| `WLT_API_MESSAGE` | **90 days** | – | year 1+ Parquet (request/response bodies stripped of PII at export time) | year 8–10 | Idempotency window short; payloads expensive to keep hot |
| `WLT_API_TRACE` | **30 days** | – | year 1+ in OpenSearch warm, then S3 | drop at 2 years | Trace data, not a compliance record |
| `WLT_OLTP_AUDIT` | 18 months | months 19–36 | year 3–7 | year 8–10 | Internal change audit |
| `WLT_PII_ACCESS_LOG` | 18 months | months 19–36 | year 3–10 | – | Per Decree 13/2023, retain ≥ 5 years; WORM-locked in archive |
| `WLT_SWEEP_LOG` | 12 months | – | year 2+ | – | Operational, not regulatory |
| `WLT_STMT_HEADER/DETAIL` | 13 months | months 14–60 | year 5–10 PDF/Parquet | year 10+ | Customer statements; 10-year retention requirement |
| `WLT_RESTRAINTS` | All active + 5 years post-removal | – | year 5+ historical | – | Legal/compliance records; never archived while ACTIVE |
| `FM_CLIENT*` (master) | All active + 5 years post-closure | – | year 5+ post-closure | – | See §8.3.6 retention rule; crypto-shred after 5 years |
| `WLT_ACCT` (master) | All active + 5 years post-closure | – | year 5+ post-closure | – | Same as `FM_CLIENT` |

> The **active customer master tables stay hot indefinitely** — they're small (millions of rows, not billions) and join into every transaction. They're never pruned, only crypto-shredded when the legal retention clock expires.

### 9a.4 Partition Lifecycle Automation (PG17)

```
Monthly job (1st of every month, 02:00 local):
  1. Create next 3 months of partitions (pg_partman pre-make)
  2. Validate previous month partition (constraints, row count vs daily sum)
  3. Run VACUUM (ANALYZE, FREEZE) on the closed month
  4. If month closed is M-14:
       ALTER TABLE ... DETACH PARTITION CONCURRENTLY
       → moves to cold replica tablespace
       → emits notification to lifecycle pipeline

Quarterly job (5th of Jan/Apr/Jul/Oct, 03:00):
  1. Identify partitions closing the 36-month boundary
  2. Export to Parquet (pg_parquet or COPY ... PROGRAM 'pg_to_parquet')
  3. Verify checksum on S3
  4. DROP PARTITION (cascades drop of indexes, no full-table lock)
  5. Update partition_catalog table with cold-storage URI

Yearly job (15th of January):
  1. MERGE 12 monthly partitions of year-now-minus-2 into a yearly partition
     (cuts catalog bloat; PG17 native MERGE PARTITION)
  2. Reindex if bloat > 30%
```

Tooling:
- **`pg_partman`** — auto-create / drop scheduled partitions
- **`pg_parquet`** (PostgreSQL extension) or native `COPY ... TO PROGRAM` — export partition to Parquet
- **`pg_cron`** — schedule the above directly inside PG
- **Airflow / Argo Workflows** — orchestrate verification + retry + alerting

### 9a.5 Backup Strategy (RPO ≤ 1 min, RTO ≤ 15 min)

| Backup type | Frequency | Storage | Retention | Restore SLA |
|-------------|-----------|---------|-----------|-------------|
| **WAL streaming** (synchronous) | Continuous | Same-region replica (synchronous) + DR-region replica (asynchronous) | 30 days | Failover < 5 min via Patroni / cloud-managed PG |
| **WAL archive** | Continuous, ship every 30s | S3 (Object Lock 30 days) | 30 days | PITR to any second in window |
| **Incremental base backup** (PG17) | Hourly | Cross-AZ object storage | 30 days | PITR baseline |
| **Full base backup** (PG17) | Weekly (Sunday 02:00) | Cross-AZ object storage + monthly copy to cross-region | 12 months | Full restore |
| **Logical dump** (`pg_dump`) | Daily | Cross-region object storage | 90 days | Per-table restore; useful for schema disasters |
| **Cross-region DR replica** | Continuous logical replication (PG17 failover slots) | Different region | Live (always current) | Region failover < 15 min |

**Recovery scenarios mapped to backups**:

| Scenario | Mechanism | RPO | RTO |
|----------|-----------|-----|-----|
| Primary node crash | Synchronous replica auto-promotes | 0 | < 1 min |
| Primary AZ failure | Cross-AZ replica promotes | < 1s | < 5 min |
| Primary region failure | Cross-region DR replica promotes (manual approval) | < 1 min (async replica lag) | < 15 min |
| Logical corruption (e.g. bad migration) | PITR from base backup + WAL archive | < 30s | 30 min–4 hours depending on rewind distance |
| Single-table corruption | `pg_dump` restore to a side schema, then `INSERT ... SELECT` | depends on dump age | 1–4 hours |
| Total cluster loss | Restore latest base backup + replay WAL | < 1 min | 4–8 hours (for full 3TB primary) |
| Cold-data query restore | Parquet → DuckDB / Trino federation, or `pg_restore` to side cluster | – | < 1 hour (interactive) |

**Backup encryption**: all backups encrypted with the same KMS-managed KEK hierarchy used for column encryption (§8.3.2). Backup keys rotated quarterly; old backups remain readable via key versioning.

**Backup verification**: nightly automated restore-test on a sandbox cluster (restore latest base backup + apply WAL to a recent point → run schema validation + row count + checksums on critical tables). Failure pages the on-call engineer.

### 9a.6 Archive Strategy

**Format**: Apache Parquet, ZSTD-19 compression, partitioned by `(year=YYYY, month=MM, acct_hash=HH)` directory layout for partition pruning on read.

**Storage**: S3-compatible object storage in two tiers:
- **Standard-IA** for years 4–7 (rare query but interactive retrieval, ~60s)
- **Deep Archive / Glacier Deep Archive** for years 8–10 (regulatory hold; expected retrieval only for audit)

**Immutability**: Object Lock in Compliance mode (S3 / Azure Immutable Blob) — objects cannot be deleted or modified for the retention period, even by root admins. This is required by NHNN audit and supports the AML record-keeping mandate.

**Query layer**:
- Daily / monthly business queries against archive: **Trino** federation or **Athena** / **BigQuery Omni**, joined with hot PG via foreign-data wrapper.
- Ad-hoc engineering queries: **DuckDB** on a local laptop pointing at S3 — single-developer access pattern.
- Customer-facing statement reproduction: a dedicated micro-service reads Parquet partitions and renders PDF on demand.

**Schema evolution**: every Parquet partition embeds a `schema_version` field. A migration registry (`archive_schema_versions` table in OLTP) maps versions to readable schemas; consumers must support N and N−1 schema versions.

**Index sidecars**: each Parquet partition has a companion `manifest.json` listing row count, min/max of `INTERNAL_KEY`, `POST_DATE`, and a Bloom filter of `REFERENCE`. Skips full file scans for point lookups.

### 9a.7 Legal Hold & Retrieval Workflow

When a court order, audit demand or regulator request lands:

1. **Submit hold** through the Compliance console → writes a row to `LEGAL_HOLD` table with `CASE_REF`, `SCOPE` (customer / account / date range), `EFFECTIVE_FROM/TO`.
2. **Hold enforcement** — a guard runs before every prune / archive transition job: if the partition or row intersects an active `LEGAL_HOLD`, the lifecycle step is **blocked** and an alert is raised. Object Lock retention is **extended**, not allowed to roll off.
3. **Retrieval request** — Compliance generates a ticketed export combining hot + warm + cold + archive data into a single signed bundle. The export goes through the masking layer unless the request explicitly authorises unmasked PII (logged in `WLT_PII_ACCESS_LOG`).
4. **Audit chain of custody** — every retrieval emits an immutable event to `LEGAL_HOLD_AUDIT` and to the SIEM.

### 9a.8 Monitoring & Operational Metrics

| Metric | Threshold | Alert |
|--------|-----------|-------|
| OLTP primary disk usage | > 75% | P2 (capacity review) |
| Partition count on `WLT_TRAN_HIST` parent | > 500 | P3 (catalog pressure — consider yearly merge) |
| WAL archive lag | > 60 s | P1 (RPO at risk) |
| DR replica lag | > 5 s | P2 |
| Backup job failure | Any | P1 |
| Nightly restore-test failure | Any | P1 |
| Archive export job lag | > 7 days behind quarterly cadence | P3 |
| Object Lock policy missing on new bucket | Any | P1 (compliance gap) |
| Bloat ratio on `WLT_ACCT` | > 30% | P2 (vacuum tuning) |

### 9a.9 Indicative 5-Year Cost Envelope

Using AWS pricing as a sanity check (cloud provider, region, contract discounts will shift these):

| Component | Year-end Y5 size | Tier | Unit cost | Annual cost (Y5) |
|-----------|------------------|------|-----------|------------------|
| Hot OLTP (PG17 on db.r6i.8xlarge multi-AZ + 4TB gp3) | ~3 TB | Hot | – | ~$60k |
| Warm replica (db.r6i.4xlarge + 6TB st1) | ~6 TB | Warm | – | ~$20k |
| Object storage Standard-IA | ~8 TB | Cold | $12.5/TB/mo | ~$1.2k |
| Object storage Deep Archive | ~6 TB | Archive | $1/TB/mo | ~$0.07k |
| Backup storage (base + WAL + dumps) | ~12 TB | – | $25/TB/mo | ~$3.6k |
| Cross-region DR + egress | – | – | – | ~$15k |
| **Total infra (Y5 run rate)** | – | – | – | **~$100k/yr** |

Engineering effort to operate the lifecycle (one part-time SRE for partition + archive jobs) is the larger ongoing cost; estimate one quarter of an SRE FTE.

### 9a.10 Failure Modes & Mitigations

| Failure | Impact | Mitigation |
|---------|--------|------------|
| Partition export to Parquet incomplete | Cold tier missing rows | Verify SHA-256 of source vs destination row counts; retry; keep partition in warm until verified |
| KMS key revoked / lost | All encrypted backups + columns unreadable | Multi-region KMS replication; backup of KEK under HSM custody; quarterly key-recovery drill |
| Object Lock policy bypassed by admin | Compliance gap | Provision buckets via Terraform with Object Lock pre-enabled; CIS-benchmark scan blocks bucket without lock |
| Archive query needs unmasked PII | Compliance violation | Compliance approval workflow gates the export; access logged immutably |
| Region failure during DR test | Test causes outage | DR tests on shadow traffic only; quarterly read-only failover, annual full failover with maintenance window |
| Storage growth outpaces budget | Cost overrun | Monthly storage-growth report; auto-alert when actual > forecast × 1.2 |

### 9a.11 Roll-out Phasing

| Phase | When | Deliverable |
|-------|------|-------------|
| **Foundation** (Y0 — pre-launch) | Before P0 go-live | pg_partman + monthly partitions; weekly base backup + WAL streaming; same-region standby; KMS hierarchy; Object Lock buckets provisioned |
| **Hot/Warm split** | Mid-Y1 | Cold replica with cheaper tablespace; DETACH workflow; first partition handoff |
| **Cold tier** | End of Y2 | Parquet export pipeline operational; Trino/Athena query layer; cross-region DR active |
| **Archive tier** | Y4 | First objects transitioning to Deep Archive; legal-hold workflow live |
| **Mature** | Y5 | All four tiers in production, restore-test in CI/CD, quarterly DR failover drills |

---

## 10. Phases / Roadmap

| Phase | Scope | Timeline |
|-------|-------|----------|
| **P0** | VND wallet + in-book transfer | M0–M3 |
| **P1** | Bank top-up (1 partner bank) + withdraw | M4–M6 |
| **P2** | Merchant payment + QR + multi-bank top-up | M7–M9 |
| **P3** | KYC tier 2/3 + recurring + bill payment | M10–M12 |
| **P4** | Multi-currency, cross-border (subject to licence) | Y2 |

---

## 11. Assumptions & Open Questions

### Assumptions
1. The payment-intermediary licence has been granted by the SBV.
2. A contract with at least one partner bank to open the TKĐBTT is in place.
3. Contracts with NAPAS / an eKYC provider are in place.
4. Year-1 transaction volume < 50 million transactions / month.
5. **FM (Foundation Master) is a shared module**: if the organization already runs T24 core banking → reuse the existing FM; if building greenfield → FM must be prioritized before WLT.

### Open Questions
- [ ] Ledger model: single-DB or event-sourced?
- [ ] Sharding strategy beyond 10M wallets?
- [ ] Multi-tenancy (white-label) — required from P0?
- [ ] FM ownership: which team owns it? What is the maker-checker workflow?

---

## 12. Appendix — Wallet feature ↔ FM table mapping

| Wallet feature | FM table referenced | Purpose |
|----------------|--------------------|---------|
| Open wallet | `FM_CLIENT`, `FM_CLIENT_INDVL`, `FM_CLIENT_IDENTIFIERS`, `FM_CLIENT_CONTACT` | Shared customer master |
| KYC | `FM_CLIENT_IDENTIFIERS` | Store identification data (CCCD, passport) |
| Linked bank | `FM_CLIENT_BANKS` | Store customer's bank account for top-up/withdraw |
| CCY config | `FM_CURRENCY` | Decimal places, day basis |
| Posting GL | `FM_GL_MAST` | Chart of accounts (incl. fee revenue GL 401.x, VAT payable 203.x) |
| TKĐBTT | `FM_NOS_VOS` | Nostro/vostro master |
| Fee revenue & VAT GL | `FM_GL_MAST` (`401.01`, `203.01`) | Fee revenue GL + VAT payable GL |

---

## 13. References
- `t24_transaction_posting.md` — 6-step pipeline used as the basis for the Posting Engine
- `tab_rb.xlsx` — RB schema reference (retail banking transactional, 348 tables)
- `TAB_FM.xlsx` — FM schema reference (foundation master, 344 tables)
- Decree 52/2024/NĐ-CP — non-cash payments
- Circular 23/2019/TT-NHNN — payment intermediary
- DDL details, ERD, sequence diagrams: see `wallet_DLD.md`
- Onboarding BRD + KYC tier rules + wallet opening flow + API spec: see `wallet_onboarding.md`
- BRD + API for top-up/deposit/withdraw/transfer/reversal/history with the Fee & VAT engine: see `finance_transaction.md`
- Operational seed (`WLT_ACCT_TYPE` values, sequences), helper functions (`fn_create_client`, `fn_open_wallet`), bulk test-data generator: see `wallet_seed.sql`
- Consolidated error catalog (public + internal), response envelope, severity, retry policy, exception mapping: see `error_management.md`
