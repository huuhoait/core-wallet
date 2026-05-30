# Error Code Management — Core Account E-Wallet

**Version**: 1.6
**Date**: 2026-05-30
**Status**: Draft
**Author**: Core Wallet Team

**Changelog**
- v1.6 (2026-05-30): **Doc↔code reconcile + RFC 7807 envelope shipped.** Decision: canonical = implemented code names (§14.2). §3 envelope rewritten to the implemented `application/problem+json` (RFC 7807) shape with `iso20022_reason_code` + `transaction_status`. Added **§4.0 Implemented codes (canonical/authoritative)**. Code side (`services/wallet-service`): `ErrorResponse` → `ProblemDetails`; HTTP-status fixes (`INSUFFICIENT_FUNDS` 402→422, `TIER_LIMIT_EXCEEDED` 429→422, restraints 403→423); `DUPLICATE_REQUEST`→`DUPLICATE_REFERENCE`; ISO-20022 reason registry + `transaction_status` on async responses; Go tests added.
- v1.5 (2026-05-30): Added **§13 ISO 20022 & PSD2 (Berlin Group) alignment** and **§14 Appendix A — error-code crosswalk** (public code ↔ internal ↔ ISO 20022 External Status Reason ↔ Berlin Group message code ↔ `pain.002` `transactionStatus`). Consolidated the duplicated §7 idempotency subsection (replay = idempotent 2xx; `409 DUPLICATE_REFERENCE` only on `PAYLOAD_HASH` collision). Documented the divergence between this catalog and the implemented Go codes (`services/wallet-service/internal/domain/errors.go`) in §14.2 and proposed a single canonical set.
- v1.4 (2026-05-28): Added `POSTING_TIMEOUT` (E9004), `DB_CONTENTION` (E9005), `POOL_EXHAUSTED` (E9006) for Go service + plpgsql SP architecture. Rewrote §7 retry policy following 3s/2.5s/1.5s timeout layering.
- v1.3 (2026-05-28): Added `REVERSAL_BLOCKED_BY_RESTRAINT` (E6005) for hard-stop when reversing a transaction whose purpose ∈ {`COURT_ORDER`,`AML_HOLD`}.
- v1.2 (2026-05-28): Split `RESTRAINT_TYPE` (Debit/Credit/All/Info) and `RESTRAINT_PURPOSE` following T24 convention; added `ACCT_CR_RESTRAINED`, `RESTRAINT_PURPOSE_INVALID`, `RESTRAINT_TYPE_PURPOSE_CONFLICT`; renumbered E3010-E3015 → E3020-E3027 to leave room for expanded wallet account codes.
- v1.1 (2026-05-28): Added error codes for Restraint Management (`finance_transaction.md §8`) and Get Balance (`finance_transaction.md §9`); updated cross-refs when finance_transaction was renumbered.
- v1.0 (2026-05-28): First version — consolidated error codes scattered across `wallet_onboarding.md §9`, `finance_transaction.md §12`, `wallet_DLD.md §6.2` into a single source of truth; standardized envelope, severity, retry policy, internal error mapping.

---

## 1. Objectives & Scope

### 1.1 Objectives
- **Single source of truth** for every public (API) and internal (logging) error code in the Core Wallet system.
- Standardize the **response envelope** so FE/partner can handle errors uniformly.
- Define **severity** + **retry policy** for consistent ops alerting and SDK behavior.
- Map internal exceptions (DB, Java, downstream) → external codes to avoid leaking system details.

### 1.2 Scope
- Covers all 9 modules in HLD §4: API Gateway, FM, Account Management, Posting Engine, Fee & VAT, Ledger/GL Feed, Reconciliation, Statement/Reporting, Notification.
- Applies to every public API (REST), webhook callback, partner integration (NAPAS, partner bank).
- Internal job errors (recon break, GL feed fail) also use this catalog for log consistency.

### 1.3 Out of scope
- Pure infra errors (network, OS-level) — owned by SRE, not in the business catalog.
- Compile/build errors — not runtime business errors.

---

## 2. Error code design principles

| # | Principle | Notes |
|---|-----------|-------|
| 1 | **Stable**: code meaning does not change between versions | Deprecation means adding a new code + keeping the old one ≥ 6 months |
| 2 | **Self-describing**: code name is immediately understandable | `INSUFFICIENT_FUND`, not `ERR_42` |
| 3 | **Format**: `SCREAMING_SNAKE_CASE`, ≤ 32 characters | Avoid accents and Vietnamese |
| 4 | **No duplicate meanings**: 1 business case → 1 code | Already merged `EKYC_FAIL` / `EKYC_FAIL_LOW_SCORE` (kept the longer name) |
| 5 | **HTTP + code in parallel**: HTTP for retry semantics, code for business semantics | Caller MUST read both |
| 6 | **Internal code in parallel**: every public code has one `E{domain}{seq}` internal code for log/alert | Mapped in §5 |
| 7 | **Do not leak system details**: never return stack trace, table name, SQL | `INTERNAL_ERROR` is the last-resort code |
| 8 | **i18n message separated**: code is the contract; Vietnamese/English messages are generated from a resource bundle | Callers should not parse messages |

### 2.1 HTTP status conventions

| HTTP | Meaning | When to use |
|------|---------|-------------|
| 400 | Bad request — wrong schema/format | `INVALID_PAYLOAD`, `INVALID_PHONE_FORMAT`, `SELF_TRANSFER` |
| 401 | Unauthenticated — auth failed | `UNAUTHORIZED`, `OTP_INVALID` |
| 403 | Forbidden — auth OK but insufficient permission/tier | `KYC_TIER_INSUFFICIENT` |
| 404 | Not found — resource does not exist | `ACCT_NOT_FOUND`, `ORIGINAL_NOT_FOUND` |
| 409 | Conflict — uniqueness/idempotency/state violation | `DUPLICATE_REFERENCE`, `ALREADY_REVERSED`, `PHONE_ALREADY_REGISTERED` |
| 410 | Gone — expired, not retryable | `OTP_EXPIRED`, `WINDOW_EXPIRED`, `GONE_ONLINE` |
| 422 | Unprocessable — schema OK but business rule fails | `INSUFFICIENT_FUND`, `LIMIT_EXCEEDED`, `EKYC_*` |
| 423 | Locked — resource is locked/restrained | `ACCT_BLOCKED`, `ACCT_RESTRAINED`, `CLIENT_BLOCKED` |
| 429 | Rate limited | `RATE_LIMITED`, `OTP_RATE_LIMITED` |
| 500 | Internal error — bug, unexpected exception | `INTERNAL_ERROR` (catch-all) |
| 503 | Service unavailable — downstream/maintenance | `DOWNSTREAM_TIMEOUT`, `MAINTENANCE` |

> **Rule**: if retry **could** succeed (transient), use 5xx; if it will **never** succeed with the current input, use 4xx.

---

## 3. Error response envelope

Every error is returned as **`application/problem+json`** (RFC 7807 / RFC 9457)
with bank extensions. This is the shape the service emits today
(`services/wallet-service/internal/http/dto.ProblemDetails`); the standards
rationale is in §13.4–13.5. (401 may instead be generated by the gateway per the
OAuth2 spec.)

```json
{
  "type":                 "https://docs.wallet.example/errors/INSUFFICIENT_FUNDS",
  "title":                "Insufficient funds",
  "status":               422,
  "detail":               "balance 50000 < required 100000",
  "instance":             "/v1/finance/transfer",
  "code":                 "INSUFFICIENT_FUNDS",
  "internal_code":        "E4022",
  "iso20022_reason_code": "AM04",
  "transaction_status":   "RJCT",
  "trace_id":             "01J9XK5T7R8M2N3P4Q5S6V7W8X",
  "timestamp":            "2026-05-30T10:23:45+07:00",
  "retry":   { "retryable": false, "after_ms": null },
  "details": { "balance": 50000, "required": 100000, "ccy": "VND" },
  "errors":  [ { "path": "amount", "code": "AM04", "message": "exceeds available balance" } ]
}
```

> Media type `application/problem+json`. The previous nested `{ "error": { … } }`
> shape (≤ v1.4) is **superseded** — fields are now top-level.

### 3.1 Required fields

| Field | Required | Description |
|-------|----------|-------------|
| `title` | ✅ | Short human title (RFC 7807) |
| `status` | ✅ | HTTP status code (RFC 7807) |
| `code` | ✅ | Public business code, stable contract |
| `internal_code` | ✅ | Internal code for log/alert (see §5) |
| `trace_id` | ✅ | ULID/UUID = `X-Request-Id`; must equal `WLT_API_TRACE.TRACE_ID` |
| `timestamp` | ✅ | RFC 3339 + tz |

### 3.2 Optional fields

| Field | When present |
|-------|--------------|
| `type` / `instance` | RFC 7807 doc URI / request path (best-effort) |
| `detail` | Human-readable, safe-to-display context |
| `iso20022_reason_code` | When the business reason maps to ISO 20022 (§13.2 / §14.1) |
| `transaction_status` | Posting-path + async flows (`RJCT` / `PDNG` / …) — see §13.3 |
| `details` | Structured context (balance, required, score…) |
| `retry` | `retryable` always present; `after_ms` only when retryable |
| `errors` | Field-level validation failures (`path`, `code`, `message`) |

### 3.3 Never returned

- Stack trace, exception class name (Java/Python).
- DB table name, column name, SQL state.
- Credentials, tokens, PII that do not belong to the caller.
- Unsanitized free-text user input (XSS risk).

---

## 4. Consolidated catalog

All public codes in the system. The **Module** column shows where the code is raised; the **Domain** column is used for log/alert grouping.

> **§4.0 is authoritative for what the service emits today.** §4.1–§4.10 are the
> broader catalog (including not-yet-built modules — onboarding, partner, restraint
> management). Where a name differs between §4.0 and §4.1–§4.10, **the §4.0 name
> wins** (canonical = implemented; decision recorded in §14.2).

### 4.0 Implemented codes (canonical)

Codes actually raised by the service (`internal/domain/errors.go` + the posting
SPs), with the HTTP status the service returns and the ISO 20022 mapping (§13).
Success responses additionally carry `transaction_status` (`ACSC` settled /
`ACTC` accepted-pending / `ACSP` in-process) per §13.3.

| HTTP | Code | Internal | ISO 20022 | err `tx` | Raised by |
|:----:|------|----------|-----------|:--------:|-----------|
| 400 | `INVALID_REQUEST` | E4001 | — | `RJCT` | request binding / validation |
| 400 | `INVALID_AMOUNT` | E4024 | `AM12` | `RJCT` | posting SP |
| 400 | `AMOUNT_OUT_OF_RANGE` | E4024 | `AM02` | `RJCT` | posting SP |
| 400 | `SAME_ACCOUNT` | E4002 | `BE01` | `RJCT` | transfer SP |
| 400 | `TRAN_TYPE_INACTIVE` | E4003 | `AG02` | `RJCT` | posting SP |
| 400 | `METADATA_TOO_LARGE` | E4007 | — | `RJCT` | metadata validation |
| 400 | `METADATA_HAS_P1` | E4008 | — | `RJCT` | metadata validation |
| 403 | `TIER_INSUFFICIENT` | E2007 | `RR04` | `RJCT` | posting SP |
| 404 | `ACCT_NOT_FOUND` (+ `FROM_`/`TO_` variants) | E3001 | `AC01` | `RJCT` | posting SP |
| 403 | `ACCT_NOT_ACTIVE` (+ variants) | E3004 | `AC04` | `RJCT` | posting SP |
| 422 | `INSUFFICIENT_FUNDS` | E4022 | `AM04` | `RJCT` | posting SP |
| 422 | `TIER_LIMIT_EXCEEDED` | E4023 | `AM02` | `RJCT` | posting SP |
| 423 | `DR_RESTRAINT_ACTIVE` | E3005 | `AC06` | `RJCT` | posting SP |
| 423 | `CR_RESTRAINT_ACTIVE` | E3006 | `AC06` | `RJCT` | posting SP |
| 409 | `DUPLICATE_REFERENCE` | E4011 | `AM05` | — | unique_violation (23505) |
| 409 | `VERSION_CONFLICT` | E4025 | — | `PDNG` | optimistic conflict — **retryable** |
| 404 | `WD_NOT_FOUND` | E6101 | — | — | mark / reversal SP |
| 409 | `WD_INVALID_STATE` | E6103 | — | — | mark SP |
| 409 | `WD_ALREADY_COMPLETED` | E6102 | — | — | mark SP |
| 409 | `WD_ALREADY_REVERSED` | E6104 | — | — | reversal SP |
| 422 | `INVALID_DATE` | E8003 | `DT01` | — | balance (as-of) |
| 422 | `BATCH_SIZE_EXCEEDED` | E8004 | — | — | balance (batch) |
| 410 | `GONE_ONLINE` | E8001 | — | — | balance (historical) |
| 500 | `PII_DEK_NOT_SET` | E5005 | — | `PDNG` | withdraw encryption |
| 504 | `TIMEOUT` | E9004 | — | `PDNG` | ctx deadline / 57014 (503 on 55P03 lock_timeout) |
| 500 | `INTERNAL_ERROR` | E9001 | — | `PDNG` | unmapped fallback |

> Restraint codes (`RESTRAINT_TYPE_INVALID`/`PURPOSE_INVALID`/`TYPE_PURPOSE_CONFLICT`/`AMT_EXCEEDS_BALANCE`/`DATE_INVALID` → 422, `RESTRAINT_ALREADY_REMOVED` → 409, `RESTRAINT_NOT_FOUND` → 404, `COURT_ORDER_REMOVE_REQUIRES_DOC` → 422) are now implemented too (SP `add_restraint`/`release_restraint`) — listed in §4.9.
>
> Client master CRUD (SP `create_client`/`update_client`): `INVALID_CLIENT_TYPE` (E2010) → 422, `CLIENT_ALREADY_EXISTS` (E2009, ISO `AM05`) → 409, `CLIENT_NOT_FOUND` (E2011) → 404.
>
> Client linked-bank management (SP `link_client_bank`/`set_default_client_bank`): `CLIENT_NOT_FOUND` → 404, `BANK_LINK_NOT_FOUND` (E2012) → 404, `INVALID_REQUEST` (missing `bank_code`/`acct_no`) → 400, `PII_DEK_NOT_SET` → 500 (acct_no encryption). Endpoints: `POST /v1/clients/:client_no/banks`, `PUT /v1/clients/:client_no/banks/:link_id/default`.
>
> Account lifecycle (SP `open_account`/`update_account_status`): `INVALID_ACCT_TYPE` (E3007) → 422, `MAX_WALLET_PER_CLIENT_EXCEEDED` (E3002) → 409, `ACCT_CLOSE_NONZERO_BAL` (E3003) → 422, `ACCT_NOT_ACTIVE` (closed/terminal) → 403.

### 4.1 Auth & rate limiting

| HTTP | Code | Internal | Module | Caller action |
|------|------|----------|--------|---------------|
| 401 | `UNAUTHORIZED` | E1001 | Gateway | Re-auth, refresh token |
| 401 | `OTP_INVALID` | E1002 | Onboarding | Allow retry, count attempts (max 5) |
| 410 | `OTP_EXPIRED` | E1003 | Onboarding | Resend OTP |
| 429 | `RATE_LIMITED` | E1004 | Gateway | Exponential backoff, read `after_ms` |
| 429 | `OTP_RATE_LIMITED` | E1005 | Onboarding | Wait for cooldown (default 60s) |
| 403 | `FORBIDDEN_NOT_OWNER` | E1006 | Account, Balance | Customer can only operate on their own wallet |
| 403 | `FORBIDDEN_RESTRAINT_ROLE` | E1007 | Restraint | Requires role `OPS_RESTRAINT_MAKER/CHECKER` |
| 403 | `RESTRAINT_MAKER_CANNOT_CHECK` | E1008 | Restraint | Maker-checker: user adding ≠ user removing |

### 4.2 Onboarding & KYC

| HTTP | Code | Internal | Module | Caller action |
|------|------|----------|--------|---------------|
| 400 | `INVALID_PHONE_FORMAT` | E2001 | Onboarding | Validate VN format `^(\+84\|0)[0-9]{9}$` |
| 409 | `PHONE_ALREADY_REGISTERED` | E2002 | Onboarding | Log in instead of registering |
| 409 | `CCCD_ALREADY_USED` | E2003 | Onboarding | Contact customer service |
| 422 | `CCCD_EXPIRED` | E2004 | Onboarding | Update ID document |
| 422 | `EKYC_FAIL_LOW_SCORE` | E2005 | Onboarding | Retry with clearer photo (max 3 attempts) |
| 422 | `EKYC_LIVENESS_FAIL` | E2006 | Onboarding | Retry; 3 failures → manual review |
| 403 | `KYC_TIER_INSUFFICIENT` | E2007 | Onboarding, Tran | Upgrade tier before operating |
| 423 | `CLIENT_BLOCKED` | E2008 | Onboarding, Tran | Contact ops (AML/CFT case) |

### 4.3 Wallet account

| HTTP | Code | Internal | Module | Caller action |
|------|------|----------|--------|---------------|
| 404 | `ACCT_NOT_FOUND` | E3001 | Account, Tran | Check `acct_no` |
| 409 | `MAX_WALLET_PER_CLIENT_EXCEEDED` | E3002 | Account | Close an old wallet or use an existing one |
| 422 | `ACCT_CLOSE_NONZERO_BAL` | E3003 | Account | Transfer out the full balance before closing |
| 423 | `ACCT_BLOCKED` | E3004 | Account, Tran | Contact customer service |
| 423 | `ACCT_RESTRAINED` | E3005 | Tran (DR) | Has restraint type ∈ {`DEBIT`,`ALL`} blocking everything — contact ops |
| 423 | `ACCT_CR_RESTRAINED` | E3006 | Tran (CR) | Has restraint type ∈ {`CREDIT`,`ALL`} — cannot receive funds |

### 4.4 Transaction posting

| HTTP | Code | Internal | Module | Caller action |
|------|------|----------|--------|---------------|
| 400 | `INVALID_PAYLOAD` | E4001 | Gateway, Tran | Fix request schema |
| 400 | `SELF_TRANSFER` | E4002 | Tran (Transfer) | Pick different `to_acct` |
| 400 | `INVALID_TRAN_TYPE` | E4003 | Tran | `TRAN_TYPE` does not exist in `WLT_TRAN_DEF` |
| 400 | `INVALID_CCY` | E4004 | Tran | `CCY` does not match `FM_CURRENCY` |
| 409 | `DUPLICATE_REFERENCE` | E4011 | Tran (all write) | Return the previous response (idempotent replay) |
| 422 | `INSUFFICIENT_FUND` | E4022 | Tran (Transfer, Withdraw, Deposit fee) | Top up more |
| 422 | `LIMIT_EXCEEDED` | E4023 | Tran (all write) | Wait for reset / upgrade tier |
| 422 | `AMOUNT_OUT_OF_RANGE` | E4024 | Tran | Check `WLT_TRAN_DEF.MIN_AMT/MAX_AMT` |
| 422 | `OPTIMISTIC_LOCK_FAILED` | E4025 | Posting Engine | Auto-retry max 3 times (SDK), then surface 503 |

### 4.5 Fee, VAT & GL

| HTTP | Code | Internal | Module | Caller action |
|------|------|----------|--------|---------------|
| 422 | `FEE_CONFIG_MISSING` | E5001 | Fee Engine | Ops: add row to `WLT_TRAN_DEF` |
| 500 | `GL_CODE_NOT_FOUND` | E5002 | Posting, GL Feed | Ops: ensure `FM_GL_MAST` contains the GL code |
| 500 | `DR_CR_UNBALANCED` | E5003 | Posting | Critical bug — page on-call immediately |
| 500 | `NOSTRO_LINK_MISSING` | E5004 | Posting | Ops: add `WLT_NOSTRO_LINK` |

### 4.6 Reversal

| HTTP | Code | Internal | Module | Caller action |
|------|------|----------|--------|---------------|
| 404 | `ORIGINAL_NOT_FOUND` | E6001 | Reversal | Check `original_tran_id` |
| 409 | `ALREADY_REVERSED` | E6002 | Reversal | No action needed — already reversed |
| 410 | `WINDOW_EXPIRED` | E6003 | Reversal | Manual dispute (via ops) |
| 422 | `BALANCE_INSUFFICIENT_TO_REVERSE` | E6004 | Reversal | Dispute workflow — customer B has already spent |
| 423 | `REVERSAL_BLOCKED_BY_RESTRAINT` | E6005 | Reversal | Remove the `COURT_ORDER`/`AML_HOLD` restraint first (see `finance_transaction.md` REV-08) |

### 4.7 Partner / downstream

| HTTP | Code | Internal | Module | Caller action |
|------|------|----------|--------|---------------|
| 422 | `PARTNER_DECLINED` | E7001 | Topup, Withdraw | Check bank/card; customer contacts originating bank |
| 503 | `DOWNSTREAM_TIMEOUT` | E7002 | Topup, Withdraw, eKYC | Retry after `after_ms` |
| 503 | `PARTNER_UNAVAILABLE` | E7003 | Topup, Withdraw | Try a different partner / report to SBV if prolonged |

### 4.8 History / Statement

| HTTP | Code | Internal | Module | Caller action |
|------|------|----------|--------|---------------|
| 410 | `GONE_ONLINE` | E8001 | Statement, Balance (historical) | History > 18 months → request archive |
| 422 | `INVALID_CURSOR` | E8002 | Statement | Start over from the first page |
| 422 | `INVALID_DATE` | E8003 | Balance (historical) | `as_of_date` must be < today |
| 422 | `BATCH_SIZE_EXCEEDED` | E8004 | Balance (batch) | Split into multiple batches ≤ 100 |

### 4.9 Restraint

| HTTP | Code | Internal | Module | Caller action |
|------|------|----------|--------|---------------|
| 404 | `RESTRAINT_NOT_FOUND` | E3020 | Restraint | Check `restraint_id` |
| 409 | `RESTRAINT_ALREADY_REMOVED` | E3021 | Restraint | Already in `STATUS='R'` or `'E'` — no action needed |
| 422 | `RESTRAINT_TYPE_INVALID` | E3022 | Restraint | Use enum {`DEBIT`,`CREDIT`,`ALL`,`INFO`} (see `finance_transaction.md §8.2.1`) |
| 422 | `RESTRAINT_PURPOSE_INVALID` | E3023 | Restraint | Use a valid enum (see `finance_transaction.md §8.2.2`) |
| 422 | `RESTRAINT_TYPE_PURPOSE_CONFLICT` | E3024 | Restraint | E.g. `COURT_ORDER` must be `ALL`; `PLEDGE` must be `DEBIT` (see RST-11) |
| 422 | `RESTRAINT_AMT_EXCEEDS_BALANCE` | E3025 | Restraint | `pledged_amt` must not exceed `ACTUAL_BAL` (applies only to `DEBIT`/`ALL`) |
| 422 | `RESTRAINT_DATE_INVALID` | E3026 | Restraint | `end_date` ≥ `start_date` |
| 422 | `COURT_ORDER_REMOVE_REQUIRES_DOC` | E3027 | Restraint | `COURT_ORDER` / `TAX_LIEN` requires `reference_doc` |

### 4.10 System

| HTTP | Code | Internal | Module | Caller action |
|------|------|----------|--------|---------------|
| 500 | `INTERNAL_ERROR` | E9001 | All | Retry with backoff (idempotent only) |
| 503 | `MAINTENANCE` | E9002 | Gateway | Wait for the maintenance window |
| 503 | `CIRCUIT_OPEN` | E9003 | Gateway | Long backoff (default 30s) |
| 504 | `POSTING_TIMEOUT` | E9004 | Go service | `context.WithTimeout(3s)` exceeded — retry with a new REFERENCE or check status via replay |
| 503 | `DB_CONTENTION` | E9005 | Go service | PG lock_timeout / deadlock — retry after long backoff (1s) |
| 503 | `POOL_EXHAUSTED` | E9006 | Go service | pgxpool acquire fail — capacity issue, scale up |

---

## 5. Internal exception → public code mapping

This mapping table helps developers know which public code to translate an internal exception into. Any exception **without** a mapping ⇒ falls back to `INTERNAL_ERROR` (E9001) + alert.

| Internal exception / SQLState | Public code | Notes |
|------------------------------|-------------|-------|
| `OptimisticLockException` (JPA), `40001` (PG serialization_failure) | `OPTIMISTIC_LOCK_FAILED` (E4025) | SDK auto-retries 3 times |
| `23505` (PG unique_violation) on `REFERENCE` | `DUPLICATE_REFERENCE` (E4011) | Replay → return previous response from `WLT_API_MESSAGE` |
| `23503` (PG fk_violation) on `ACCT_NO` | `ACCT_NOT_FOUND` (E3001) | – |
| `23503` (PG fk_violation) on `GL_CODE` | `GL_CODE_NOT_FOUND` (E5002) | Critical — page ops |
| `CHECK constraint` `chk_balance_nonneg` | `INSUFFICIENT_FUND` (E4022) | DR exceeding balance blocked by DB |
| `40P01` (PG deadlock_detected) | `OPTIMISTIC_LOCK_FAILED` (E4025) | Retry; if recurring → review lock order |
| `57014` (PG query_canceled) — statement timeout | `DOWNSTREAM_TIMEOUT` (E7002) | DB unusually slow |
| `08006` (PG connection_failure) | `INTERNAL_ERROR` (E9001) | Connection pool / DB down |
| `TimeoutException` when calling NAPAS/bank | `DOWNSTREAM_TIMEOUT` (E7002) | + circuit breaker |
| `CircuitBreakerOpenException` | `CIRCUIT_OPEN` (E9003) | – |
| `JwtException`, `ExpiredJwtException` | `UNAUTHORIZED` (E1001) | – |
| Any unclassified exception | `INTERNAL_ERROR` (E9001) | **Must** alert ops |

---

## 6. Severity & alerting

Severity is attached to internal codes and drives PagerDuty/Slack routing.

| Severity | Trigger | Routing | Example codes |
|----------|---------|---------|---------------|
| **P1 — Critical** | Ledger correctness / compliance violation | Page on-call 24/7 immediately | `DR_CR_UNBALANCED` (E5003), settlement account < Σ wallets |
| **P2 — High** | Downstream/dependency down, widespread impact | Page during business hours + Slack #incident | `PARTNER_UNAVAILABLE` (E7003), `INTERNAL_ERROR` rate > 1% over 5 minutes |
| **P3 — Medium** | Config error, missing reference data | Ops ticket, no page | `FEE_CONFIG_MISSING` (E5001), `GL_CODE_NOT_FOUND` (E5002) |
| **P4 — Low** | Customer-caused error (4xx) | No alert; dashboard only | `INSUFFICIENT_FUND`, `LIMIT_EXCEEDED` |
| **P5 — Info** | Idempotent replay, expected 4xx volume | Dashboard only | `DUPLICATE_REFERENCE` |

### 6.1 Default alert thresholds

| Metric | Threshold | Severity |
|--------|-----------|----------|
| `INTERNAL_ERROR` rate | > 1% / 5min | P2 |
| `DR_CR_UNBALANCED` count | ≥ 1 | P1 |
| `OPTIMISTIC_LOCK_FAILED` rate | > 5% / 5min | P3 (review lock contention) |
| `DOWNSTREAM_TIMEOUT` rate per partner | > 10% / 5min | P2 |
| Total 5xx rate | > 0.5% / 5min | P2 |
| 422 `INSUFFICIENT_FUND` rate | spike > 3× baseline | P3 (possible fraud probing) |

---

## 7. Retry policy

### 7.1 Timeout layering (Go service → PG)

| Layer | Hard limit | Set at |
|-------|------------|--------|
| Client/SDK ↔ Gateway | 5s (gateway timeout) | API gateway config |
| Gateway ↔ Go service | 4s | Gateway proxy timeout |
| Go service request (`context.WithTimeout`) | **3s** | `r.Context()` + `WithTimeout(3*time.Second)` |
| PG `statement_timeout` | 2.5s | `ALTER DATABASE` or pgxpool runtime params |
| PG `lock_timeout` | 1.5s | Same source |
| Optimistic retry budget in Go | ~150ms (10+30+100 backoff) | In code |
| Actual single SP execution | 5-15ms typical | – |

Every later layer **MUST** be ≤ the previous layer minus some buffer. Violation → the outer caller cancels before the inner finishes → orphan transaction.

### 7.2 Retry strategy by result type

| HTTP / SP result | Retry? | Strategy |
|------------------|--------|----------|
| SP `result_code = 'CONFLICT'` (optimistic) | ✅ | Backoff 10/30/100ms, max 3 times — **within the same 3s `context`** |
| SP `result_code = 'REPLAY'` (idempotency hit) | ❌ | Already succeeded — return previous response immediately |
| SP `result_code = 'REJECTED'` | ❌ | Business reject — retry is pointless |
| PG error `57014` statement_timeout | ❌ | Threshold exceeded — return 504 |
| PG error `55P03` lock_timeout | ✅ | Equivalent to CONFLICT — backoff retry |
| PG error `40P01` deadlock_detected | ✅ | Rare with deferred locking, still retry |
| `context.DeadlineExceeded` | ❌ | 3s budget exhausted — return 504 POSTING_TIMEOUT |
| pool acquire fail (`ErrAcquireTimeout`) | ❌ | Pool exhausted — return 503 |
| 5xx external (Kafka publish fail in outbox path) | ✅ | Outbox guarantees eventual delivery, does not block response |
| 429 `RATE_LIMITED` | ✅ | Read `retry.after_ms` from envelope |

### 7.3 Standard pseudocode

```go
ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
defer cancel()

backoff := []time.Duration{0, 10*time.Millisecond, 30*time.Millisecond, 100*time.Millisecond}

for attempt := 0; attempt < len(backoff); attempt++ {
    if attempt > 0 {
        select {
        case <-time.After(backoff[attempt]):
        case <-ctx.Done():
            return nil, ErrPostingTimeout
        }
    }
    
    result, err := callSP(ctx, ...)
    if err != nil {
        if isRetryableLockErr(err) { continue }
        return nil, err
    }
    
    switch result.ResultCode {
    case "POSTED", "REPLAY", "REJECTED":
        return result, nil
    case "CONFLICT":
        continue
    }
}
return nil, ErrOptimisticExhausted   // → 503 OPTIMISTIC_LOCK_FAILED
```

### 7.4 Idempotency

- Every POST write **MUST** carry a `REFERENCE` (idempotency key), unique per `CLIENT_NO + ENDPOINT + 24h`.
- **DB-level gate**: SP `INSERT WLT_API_MESSAGE ... ON CONFLICT (REFERENCE) DO NOTHING`; the server also persists a `PAYLOAD_HASH` for ≥ 24h.
- **Replay — same `REFERENCE` + same payload** → SP returns `result_code = 'REPLAY'` + the stored payload → Go re-returns the original **2xx** response. This is idempotent success, **not** an error: no `409` is raised.
- **Collision — same `REFERENCE` + different payload** (`PAYLOAD_HASH` mismatch) → `409 DUPLICATE_REFERENCE` (E4011) + `details: { "reason": "reference_collision" }`. `409` exists **only** for this collision case.
- **V1 note**: payload-hash comparison may be deferred. If only `REFERENCE` is checked, treat every replay as idempotent success (`REPLAY`) and do **not** raise `409` for an identical retry.
- ISO 20022 / catalog cross-ref: `DUPLICATE_REFERENCE` → reason `AM05` (Duplication) / `DUPL`; see §14.

> Supersedes the two earlier (conflicting) idempotency notes. `X-Request-ID` is a
> separate **transport** correlation key — see §13.6.

---

## 8. Logging & tracing

### 8.1 Every error log MUST contain

| Field | Source |
|-------|--------|
| `trace_id` | OpenTelemetry trace, = `WLT_API_TRACE.TRACE_ID` |
| `internal_code` | From catalog §4 |
| `public_code` | From catalog §4 |
| `severity` | From §6 |
| `client_no` (if present) | Authenticated context |
| `acct_no` (if present) | Request context |
| `tran_type` (if present) | Request context |
| `module` | From catalog §4 |
| `caused_by` | Original exception class + message (PII-redacted) |

### 8.2 Structured log format

```json
{
  "ts":            "2026-05-28T10:23:45.123Z",
  "level":         "ERROR",
  "trace_id":      "01J9XK5T7R8M2N3P4Q5S6V7W8X",
  "internal_code": "E4022",
  "public_code":   "INSUFFICIENT_FUND",
  "severity":      "P4",
  "module":        "posting-engine",
  "client_no":     "C0000000123",
  "acct_no":       "97010000123456",
  "tran_type":     "TRFOUT",
  "caused_by":     "BalanceCheckException: required=100000 actual=50000",
  "message":       "Số dư không đủ"
}
```

### 8.3 Retention

- ERROR + WARN: online 90 days, archived 7 years (audit/compliance).
- INFO/DEBUG: online 14 days.
- `WLT_API_TRACE`: per HLD §7 data retention (online 18 months).

---

## 9. Versioning & deprecation

| Situation | Process |
|-----------|---------|
| **Add a new code** | Add to catalog §4 + §5 + changelog; deploy backward compatible |
| **Change a code's meaning** | ❌ Not allowed — must deprecate + create a new code |
| **Deprecate a code** | Mark deprecated in catalog, continue raising for at least **6 months**, log a warning when raised, sunset announcement via release notes |
| **Change HTTP status** | Considered breaking — major API version |
| **Change `internal_code`** | Avoid as much as possible; if it must change → log both the old code for ≥ 3 months |

---

## 10. Cross-reference with existing specs

This file is the **single source of truth**. Error sections in other specs will point here instead of duplicating:

| Spec | Section | Action |
|------|---------|--------|
| `wallet_onboarding.md` | §9 Error handling | Keep onboarding-only snippet; point to §4.1/4.2 of this file |
| `finance_transaction.md` | §12 Error code matrix | Keep transaction-only snippet; point to §4.4/4.6/4.7/4.9 of this file |
| `wallet_DLD.md` | §6.2 Error code mapping | Keep DLD-level snippet; point to §5 (internal mapping) of this file |
| `wallet_HLD.md` | §13 References | Add a reference line for `error_management.md` |

> **Rule**: when adding a new error code in any spec, MUST update catalog §4 in this file first; other specs only point here.

---

## 11. Acceptance criteria

| AC | Scenario | Expected |
|----|----------|----------|
| EM-01 | API returns 422 INSUFFICIENT_FUND | Response matches envelope §3, has `internal_code=E4022`, has `trace_id` matching `WLT_API_TRACE` |
| EM-02 | Replay request with same REFERENCE | Returns previous response from `WLT_API_MESSAGE` or 409 `DUPLICATE_REFERENCE` (E4011), no double posting |
| EM-03 | DB throws `40001` serialization_failure | SDK retries 3 times with exponential backoff; if still failing → 503 + log internal_code=E4025 |
| EM-04 | DR ≠ CR within a single `TFR_INTERNAL_KEY` | Raise E5003 `DR_CR_UNBALANCED` + P1 page on-call immediately; transaction rollback |
| EM-05 | NAPAS timeout > 5s | `DOWNSTREAM_TIMEOUT` (E7002); circuit breaker opens after 3 consecutive failures |
| EM-06 | Exception with no mapping in §5 | Fallback `INTERNAL_ERROR` (E9001); log full caused_by; P2 alert |
| EM-07 | Error response leaks no stack trace / SQL / PII | Inspect log + response body, no sensitive info visible |
| EM-08 | Deprecate code `X` | Catalog marks deprecated; raising still works for 6 months; log WARNING when raised |

---

## 12. Open items / TODO

- [ ] Build error catalog endpoint `GET /v1/meta/errors` (machine-readable, versioned per OpenAPI)
- [ ] i18n message bundle: `vi-VN` + `en-US` + `ko-KR` (for foreign merchants)
- [ ] Error fingerprinting: hash `(internal_code + module + caused_by)` so Sentry/Grafana groups correctly
- [ ] Webhook delivery error catalog (separate, for merchant callbacks — retry/DLQ semantics differ)
- [ ] Map NAPAS ISO8583 response codes (00, 51, 91, ...) → our public codes
- [ ] Map MT940 reject reasons → recon break codes
- [ ] Chaos testing: inject each code, verify alert routing matches severity
- [ ] Update SDK (Java/Mobile) to auto-handle retry per §7

---

## 13. ISO 20022 & PSD2 (Berlin Group) alignment

Maps the wallet's error model onto two external standards so the ledger
interoperates cleanly at the Treasury / NAPAS boundary and is ready for any
future Open-Banking exposure. The code-by-code crosswalk is in §14.

### 13.1 Scope — what applies and what does not

"PSD2 API format" in practice means the **Berlin Group NextGenPSD2 (XS2A)**
specification (alternatives: STET, UK OBIE). XS2A is a **third-party-access**
standard — consent, Strong Customer Authentication (SCA), eIDAS certificates
(QWAC/QSeal), HTTP message signing.

| Concern | Applies to the internal wallet API? |
|---------|-------------------------------------|
| Error envelope structure, message codes | ✅ Adopt (§13.4–13.5) |
| `transactionStatus` for async ops | ✅ Adopt (§13.3) |
| `X-Request-ID` header + idempotency | ✅ Adopt (§13.6) |
| Consent / SCA / TPP / eIDAS signing | ❌ Out of scope — belongs to the API-gateway / Open-Banking layer if external access is ever offered. **Do not** build it into the ledger. |

> 🇻🇳 Lớp consent/SCA/eIDAS thuộc về TPP-access, KHÔNG đưa vào ledger nội bộ.

### 13.2 ISO 20022 reason codes (highest value / lowest cost)

ISO 20022 publishes an **External Status Reason** code list (used in
`pain.002` / `pacs.002` payment-status messages). Mapping each business error to
one ISO reason code makes the wallet's rejects intelligible to any ISO 20022
counterparty (NAPAS, partner banks) without a translation layer in Treasury.
Representative mapping (full list in §14.1):

| Business case | ISO 20022 reason |
|---------------|------------------|
| Insufficient balance | `AM04` InsufficientFunds |
| Amount not allowed / over limit | `AM02` NotAllowedAmount |
| Account closed / not active | `AC04` ClosedAccountNumber |
| Account blocked / restrained | `AC06` BlockedAccount (+ `AG01` TransactionForbidden) |
| Account number unknown | `AC01` IncorrectAccountNumber |
| Duplicate reference | `AM05` Duplication / `DUPL` |
| KYC tier / regulatory | `RR04` RegulatoryReason |
| AML / court-order hold | `FRAD` FraudulentOrigin / `RR04` |
| Currency not allowed | `AM03` NotAllowedCurrency |
| Invalid date | `DT01` InvalidDate |

### 13.3 ISO 20022 `transactionStatus` for asynchronous flows

Withdrawals and merchant settlements are asynchronous (disbursement is handed to
Treasury). The `WLT_WITHDRAW_TRACK` state machine maps directly onto the ISO
20022 payment-status codes (`ExternalPaymentTransactionStatus1Code` — the same
codes Berlin Group returns from a payment `/status` resource):

| `WLT_WITHDRAW_TRACK` | ISO 20022 `transactionStatus` | Meaning |
|----------------------|-------------------------------|---------|
| `SUBMITTED` | `RCVD` | Received |
| `ACKED` | `ACTC` | AcceptedTechnicalValidation |
| `DISBURSING` | `ACSP` | AcceptedSettlementInProcess |
| `COMPLETED` | `ACSC` | AcceptedSettlementCompleted |
| `FAILED` | `RJCT` | Rejected (+ reason code) |
| `REVERSED` | — | Separate reversal (camt-style), not a status |

Recommendation: async responses carry both the existing `status` string (for
backward compatibility, ≥ 1 version) and the ISO `transaction_status`.

> **Timeout ≠ reject.** `POSTING_TIMEOUT` / `504` MUST map to `PDNG` (pending /
> outcome unknown), never `RJCT`. The caller must query status before retrying,
> or risk a double debit.

### 13.4 Envelope — options & recommendation

| Standard | Shape | Use when |
|----------|-------|----------|
| **RFC 7807** `application/problem+json` (STET-PSD2) | `type, title, status, detail, instance` + extensions | **Recommended** — IETF standard, closest to the current envelope (§3) |
| Berlin Group `tppMessages[]` | `{ "tppMessages": [{ "category", "code", "path", "text" }] }` | Only when exposing XS2A to TPPs |
| UK OBIE | `{ "Code", "Id", "Message", "Errors": [] }` | UK Open-Banking ecosystem |

**Recommendation:** adopt RFC 7807 as the base and extend it with the bank
fields already in §3 (`code`, `internal_code`, `trace_id`, `retry`) plus
`iso20022_reason_code` and (async) `transaction_status`. The business `code`
contract stays intact while gaining standard interop fields. Keep an `errors[]`
array for field-level validation (the role Berlin Group's `tppMessages` / OBIE's
`Errors` play).

### 13.5 Unified envelope (target)

```json
{
  "type":        "https://docs.wallet.example/errors/INSUFFICIENT_FUND",
  "title":       "Insufficient funds",
  "status":      422,
  "detail":      "Balance 50000 < required 100000",
  "instance":    "/v1/finance/transfer",
  "code":                 "INSUFFICIENT_FUND",
  "internal_code":        "E4022",
  "iso20022_reason_code": "AM04",
  "transaction_status":   "RJCT",
  "trace_id":             "01J9XK5T7R8M2N3P4Q5S6V7W8X",
  "timestamp":            "2026-05-30T10:23:45.123+07:00",
  "retry":   { "retryable": false, "after_ms": null },
  "errors":  [ { "path": "amount", "code": "AM04", "message": "exceeds available balance" } ]
}
```

`Content-Type: application/problem+json`. Additive over §3 (the current envelope
is a strict subset) → existing clients keep working.

### 13.6 Headers & idempotency

| Header | Direction | Purpose |
|--------|-----------|---------|
| `X-Request-ID` (UUID) | request → echoed in response | Transport correlation + idempotency (Berlin Group convention); becomes `trace_id` in the envelope |
| `Accept-Language` | request | Selects `message` locale (§3.1) |
| `Content-Type: application/problem+json` | response (errors) | RFC 7807 |

The business `REFERENCE` (§7.4) is the **posting** idempotency key;
`X-Request-ID` is the **transport** correlation/idempotency key — complementary:
`REFERENCE` survives gateway retries, `X-Request-ID` is per HTTP attempt.

### 13.7 Implementation roadmap

| Phase | Work | Risk |
|-------|------|------|
| 0 | Reconcile this catalog with the Go codes (§14.2) — pick one canonical set | doc + code rename |
| 1 | Add `iso20022_reason_code` to the catalog (§14) and to logs (§8) | doc only |
| 2 | Switch the Go `ErrorResponse` to the §13.5 envelope (RFC 7807) | code + tests |
| 3 | Return `transaction_status` on withdraw / merchant / treasury endpoints | code + Treasury contract |
| 4 | (Future, external exposure only) full Berlin Group XS2A: consent, SCA, signing, `BkTxCd` on statements | large |

### 13.8 Anti-patterns

- ❌ Mapping `504` / timeout to `RJCT` — use `PDNG` (§13.3).
- ❌ Building consent / SCA / eIDAS into the ledger — wrong layer (§13.1).
- ❌ Changing the meaning of an existing `code` — add a new code instead (§9).
- ❌ Converting wholesale to Berlin Group `tppMessages` before XS2A is exposed — unnecessary churn.

---

## 14. Appendix A — Error-code crosswalk

`—` = no direct standard equivalent (internal/technical or auth-layer code).
**tx** = `pain.002` `transactionStatus` for posting-path codes (§13.3).

### 14.1 Public catalog → ISO 20022 / Berlin Group

**Auth, KYC & account**

| Public code | HTTP | ISO 20022 reason | Berlin Group | tx |
|-------------|:----:|------------------|--------------|:--:|
| `UNAUTHORIZED` | 401 | — | `TOKEN_INVALID` | — |
| `OTP_INVALID` | 401 | — | `PSU_CREDENTIALS_INVALID` | — |
| `OTP_EXPIRED` | 410 | — | `RESOURCE_EXPIRED` | — |
| `RATE_LIMITED` / `OTP_RATE_LIMITED` | 429 | — | `ACCESS_EXCEEDED` | — |
| `FORBIDDEN_NOT_OWNER` | 403 | `AG01` | `CONSENT_INVALID` | — |
| `FORBIDDEN_RESTRAINT_ROLE` | 403 | — | — | — |
| `RESTRAINT_MAKER_CANNOT_CHECK` | 403 | — | — | — |
| `INVALID_PHONE_FORMAT` | 400 | — | `FORMAT_ERROR` | — |
| `PHONE_ALREADY_REGISTERED` | 409 | — | — | — |
| `CCCD_ALREADY_USED` | 409 | — | — | — |
| `CCCD_EXPIRED` | 422 | `RR04` | — | — |
| `EKYC_FAIL_LOW_SCORE` / `EKYC_LIVENESS_FAIL` | 422 | — | — | — |
| `KYC_TIER_INSUFFICIENT` | 403 | `RR04` | `CONSENT_INVALID` | `RJCT` |
| `CLIENT_BLOCKED` | 423 | `AC06` / `FRAD` | `SERVICE_BLOCKED` | `RJCT` |
| `ACCT_NOT_FOUND` | 404 | `AC01` | `RESOURCE_UNKNOWN` | `RJCT` |
| `MAX_WALLET_PER_CLIENT_EXCEEDED` | 409 | — | — | — |
| `ACCT_CLOSE_NONZERO_BAL` | 422 | — | `STATUS_INVALID` | — |
| `ACCT_BLOCKED` | 423 | `AC06` | `SERVICE_BLOCKED` | `RJCT` |
| `ACCT_RESTRAINED` | 423 | `AC06` / `AG01` | `SERVICE_BLOCKED` | `RJCT` |
| `ACCT_CR_RESTRAINED` | 423 | `AC06` | `SERVICE_BLOCKED` | `RJCT` |

**Posting, fee/VAT, reversal & partner**

| Public code | HTTP | ISO 20022 reason | Berlin Group | tx |
|-------------|:----:|------------------|--------------|:--:|
| `INVALID_PAYLOAD` | 400 | — | `FORMAT_ERROR` | `RJCT` |
| `SELF_TRANSFER` | 400 | `BE01` | `FORMAT_ERROR` | `RJCT` |
| `INVALID_TRAN_TYPE` | 400 | `AG02` | `PRODUCT_INVALID` | `RJCT` |
| `INVALID_CCY` | 400 | `AM03` | `FORMAT_ERROR` | `RJCT` |
| `DUPLICATE_REFERENCE` | 409 | `AM05` / `DUPL` | — | — |
| `INSUFFICIENT_FUND` | 422 | `AM04` | — | `RJCT` |
| `LIMIT_EXCEEDED` | 422 | `AM02` / `SL01` | — | `RJCT` |
| `AMOUNT_OUT_OF_RANGE` | 422 | `AM02` / `AM06` | — | `RJCT` |
| `OPTIMISTIC_LOCK_FAILED` | 422 | — (technical) | — | `PDNG` |
| `FEE_CONFIG_MISSING` | 422 | — | — | `RJCT` |
| `GL_CODE_NOT_FOUND` | 500 | — | `INTERNAL_SERVER_ERROR` | `PDNG` |
| `DR_CR_UNBALANCED` | 500 | — | `INTERNAL_SERVER_ERROR` | `PDNG` |
| `NOSTRO_LINK_MISSING` | 500 | — | `INTERNAL_SERVER_ERROR` | `PDNG` |
| `ORIGINAL_NOT_FOUND` | 404 | — | `RESOURCE_UNKNOWN` | — |
| `ALREADY_REVERSED` | 409 | — | `STATUS_INVALID` | — |
| `WINDOW_EXPIRED` | 410 | — | `RESOURCE_EXPIRED` | — |
| `BALANCE_INSUFFICIENT_TO_REVERSE` | 422 | `AM04` | — | `RJCT` |
| `REVERSAL_BLOCKED_BY_RESTRAINT` | 423 | `FRAD` / `RR04` | `SERVICE_BLOCKED` | `RJCT` |
| `PARTNER_DECLINED` | 422 | `AC04` / `AM04` (from rail) | `PAYMENT_FAILED` | `RJCT` |
| `DOWNSTREAM_TIMEOUT` | 503 | — | — | `PDNG` |
| `PARTNER_UNAVAILABLE` | 503 | — | `SERVICE_UNAVAILABLE` | `PDNG` |

**History/statement, restraint & system**

| Public code | HTTP | ISO 20022 reason | Berlin Group | tx |
|-------------|:----:|------------------|--------------|:--:|
| `GONE_ONLINE` | 410 | — | `RESOURCE_EXPIRED` | — |
| `INVALID_CURSOR` | 422 | — | `FORMAT_ERROR` | — |
| `INVALID_DATE` | 422 | `DT01` | `PERIOD_INVALID` | — |
| `BATCH_SIZE_EXCEEDED` | 422 | — | `FORMAT_ERROR` | — |
| `RESTRAINT_NOT_FOUND` | 404 | — | `RESOURCE_UNKNOWN` | — |
| `RESTRAINT_ALREADY_REMOVED` | 409 | — | `STATUS_INVALID` | — |
| `RESTRAINT_TYPE_INVALID` | 422 | — | `FORMAT_ERROR` | — |
| `RESTRAINT_PURPOSE_INVALID` | 422 | — | `FORMAT_ERROR` | — |
| `RESTRAINT_TYPE_PURPOSE_CONFLICT` | 422 | — | `FORMAT_ERROR` | — |
| `RESTRAINT_AMT_EXCEEDS_BALANCE` | 422 | `AM04` | — | — |
| `RESTRAINT_DATE_INVALID` | 422 | `DT01` | `PERIOD_INVALID` | — |
| `COURT_ORDER_REMOVE_REQUIRES_DOC` | 422 | `RR04` | `FORMAT_ERROR` | — |
| `INTERNAL_ERROR` | 500 | — | `INTERNAL_SERVER_ERROR` | `PDNG` |
| `MAINTENANCE` | 503 | — | `SERVICE_UNAVAILABLE` | `PDNG` |
| `CIRCUIT_OPEN` | 503 | — | `SERVICE_UNAVAILABLE` | `PDNG` |
| `POSTING_TIMEOUT` | 504 | — | — | **`PDNG`** |
| `DB_CONTENTION` | 503 | — | — | `PDNG` |
| `POOL_EXHAUSTED` | 503 | — | `SERVICE_UNAVAILABLE` | `PDNG` |

### 14.2 Implemented Go codes ↔ catalog (reconciliation)

**DECISION (2026-05-30): canonical = the implemented code names.** The SPs are
the source of truth for codes (the Go repo parses the `RAISE EXCEPTION` message
token), so renaming plpgsql across 5 files was rejected as higher-risk. The
authoritative implemented set is **§4.0**; the rows below are resolved **in
favour of the Go name**, and the implemented codes/HTTP statuses were aligned in
code rather than the reverse:

- HTTP statuses fixed in `repo/errors.go`: `INSUFFICIENT_FUNDS` 402 → **422**,
  `TIER_LIMIT_EXCEEDED` 429 → **422**, `*_RESTRAINT_ACTIVE` 403 → **423 Locked**.
- 23505 unique-violation now returns the canonical `DUPLICATE_REFERENCE` (was an
  ad-hoc `DUPLICATE_REQUEST`).
- `➕` codes below (WD_*, METADATA_*, PII_DEK_NOT_SET) are now documented in §4.0.

`✓` = name matches catalog · `⚠️` = catalog §4.1–4.10 uses a different name (the
**Go name is canonical** per §4.0) · `➕` = in code, now added to §4.0.

| Go constant | Catalog code (§4) | |
|-------------|-------------------|:--:|
| `ACCT_NOT_FOUND` | `ACCT_NOT_FOUND` | ✓ |
| `INVALID_DATE` | `INVALID_DATE` | ✓ |
| `GONE_ONLINE` | `GONE_ONLINE` | ✓ |
| `BATCH_SIZE_EXCEEDED` | `BATCH_SIZE_EXCEEDED` | ✓ |
| `UNAUTHORIZED` | `UNAUTHORIZED` | ✓ |
| `INTERNAL_ERROR` | `INTERNAL_ERROR` | ✓ |
| `AMOUNT_OUT_OF_RANGE` | `AMOUNT_OUT_OF_RANGE` | ✓ |
| `INSUFFICIENT_FUNDS` | `INSUFFICIENT_FUND` | ⚠️ plural |
| `SAME_ACCOUNT` | `SELF_TRANSFER` | ⚠️ rename |
| `VERSION_CONFLICT` | `OPTIMISTIC_LOCK_FAILED` | ⚠️ rename |
| `TIMEOUT` | `POSTING_TIMEOUT` | ⚠️ rename |
| `DR_RESTRAINT_ACTIVE` | `ACCT_RESTRAINED` | ⚠️ rename |
| `CR_RESTRAINT_ACTIVE` | `ACCT_CR_RESTRAINED` | ⚠️ rename |
| `ACCT_NOT_ACTIVE` | `ACCT_BLOCKED` | ⚠️ align |
| `TIER_INSUFFICIENT` | `KYC_TIER_INSUFFICIENT` | ⚠️ rename |
| `TIER_LIMIT_EXCEEDED` | `LIMIT_EXCEEDED` | ⚠️ rename |
| `TRAN_TYPE_INACTIVE` | `INVALID_TRAN_TYPE` | ⚠️ align |
| `INVALID_REQUEST` | `INVALID_PAYLOAD` | ⚠️ align |
| `FORBIDDEN` | `FORBIDDEN_NOT_OWNER` | ⚠️ align |
| `INVALID_AMOUNT` | `INVALID_PAYLOAD` / `AMOUNT_OUT_OF_RANGE` | ⚠️ no exact code |
| `METADATA_TOO_LARGE` | — | ➕ add to §4.4 |
| `METADATA_HAS_P1` | — | ➕ add to §4.4 |
| `PII_DEK_NOT_SET` | — | ➕ add to §4.10 |
| `WD_NOT_FOUND` | — | ➕ add (withdraw tracking) |
| `WD_INVALID_STATE` | — | ➕ add (→ BG `STATUS_INVALID`) |
| `WD_ALREADY_COMPLETED` | — | ➕ add (→ BG `STATUS_INVALID`) |
| `WD_ALREADY_REVERSED` | `ALREADY_REVERSED` (≈) | ⚠️ align |

---

## 15. References

- `wallet_HLD.md` §4 (modules), §7 (NFR availability/recovery), §13 (cross-reference)
- `wallet_DLD.md` §6 (Error handling & state machine), §3 (WLT_API_MESSAGE/TRACE schema)
- `wallet_onboarding.md` §9 (Onboarding error handling)
- `finance_transaction.md` §8 (Restraint), §9 (Get Balance), §12 (Error code matrix), §13 (acceptance criteria)
- `t24_transaction_posting.md` — 6-step pipeline (source of errors at each step)
- OWASP API Security Top 10 — guideline for avoiding info leaks
- RFC 7807 / RFC 9457 — Problem Details for HTTP APIs (base envelope, §13.4–13.5)
- ISO 20022 — External Code Sets (`ExternalStatusReason1Code`, `ExternalPaymentTransactionStatus1Code`); `pain.002` CustomerPaymentStatusReport (§13.2–13.3)
- Berlin Group **NextGenPSD2 XS2A** Framework — Implementation Guidelines (error model `tppMessages[]`, per-HTTP message codes, `transactionStatus`)
- STET PSD2 API — `application/problem+json` (RFC 7807) error model
- UK Open Banking (OBIE) Read/Write API — error response model
