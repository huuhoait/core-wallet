# k6 Load-Test Migration Report — PR #39 (uniform response envelope)

| | |
|---|---|
| PR | #39 — JWT/RBAC + merchant-withdraw reversal + reversal window + uniform envelope |
| Reviewer date | 2026-06-05 |
| k6 entry point | `deploy/loadtest/k6_wallet.js` |
| Driver | `deploy/loadtest/k6.sh` (`-e PEAK=300 -e DURATION=60` default) |
| Affected helpers | `outcomeLabel()`, `classify()`, `addReleaseRestraint()` |

## What changed in the wire contract

Every 2xx response (except `GET /healthz` probe) now ships in a uniform success
envelope; every error in a slimmed problem envelope. The previous flat layout
is gone.

### Success — old vs new

```diff
- 201 Created
- { "tran_internal_key": 12345, "status": "POSTED",
-   "new_balance": "100000.00", "event_uuid": "…",
-   "transaction_status": "ACTC" }
+
+ 201 Created
+ {
+   "errorCode":    "00000",
+   "errorMessage": "Success!",
+   "data": {
+     "tran_internal_key":   12345,
+     "status":              "POSTED",
+     "new_balance":         "100000.00",
+     "event_uuid":          "…",
+     "transaction_status":  "ACTC"
+   },
+   "trace_id": "req-abc-123",
+   "timestamp": "2026-06-05T15:55:00+07:00"
+ }
```

### Error — old vs new

```diff
- 422 Unprocessable Entity
- { "errorCode":    "INSUFFICIENT_FUNDS",
-   "errorMessage": "The account balance is not sufficient to cover this transaction",
-   "detail":       "balance 50000 < required 100000",
-   "internal_code": "E4022",
-   "iso20022_reason_code": "AM04",
-   "transaction_status":   "RJCT",
-   "retry":  { "retryable": false },
-   "status": 422, "title": "...", "type": "...", "instance": "..." }
+
+ 422 Unprocessable Entity
+ {
+   "errorCode":    "P0026",                              ← real PG SQLSTATE
+   "errorMessage": "INSUFFICIENT_FUNDS: balance 50000 < required 100000",
+   "detail":       "balance 50000 < required 100000",
+   "iso20022_reason_code": "AM04",
+   "transaction_status":   "RJCT",
+   "trace_id":     "req-abc-123",
+   "timestamp":    "..."
+ }
```

Whitelist gate (§3.3): unknown / internal / unexpected codes collapse to
`{ "errorCode": "999999", "errorMessage": "Internal Error" }` + HTTP 500 with
every internal hint stripped.

## What changed in `k6_wallet.js`

| Site (line in PR head) | Before | After |
|---|---|---|
| `outcomeLabel` success label | `body.status` | `body.data.status` |
| `outcomeLabel` reversal label | `body.was_already_reversed` | `body.data.was_already_reversed` |
| `outcomeLabel` error label | `body.code` | `body.errorCode` |
| `classify` post-write check | `r.json().transaction_status` | `r.json().data.transaction_status` |
| `addReleaseRestraint` id pickup | `add.json().restraint_id` | `add.json().data.restraint_id` |

The metric tag `outcome{code=…}` keeps the same dimension, but its value
domain shifts:

- **Success outcomes** unchanged in spelling — still `SUCCESS`, `DUPLICATE`,
  `SETTLEMENT_SWEEP_REQUIRED`, `REVERSED`, `REVERSED_DUP`, `BALANCE_OK`,
  `RESTRAINT_ADDED`, `RESTRAINT_RELEASED`. The script now reads them from
  `body.data.status` / `body.data.was_already_reversed`.
- **Error outcomes** change spelling — now PG SQLSTATEs / Go E#### / `999999`
  instead of canonical names.

### Outcome-label mapping (old → new)

| Scenario | Old label | New label |
|---|---|---|
| Optimistic CAS lost a race | `VERSION_CONFLICT` | `40001` |
| Wallet balance < amount | `INSUFFICIENT_FUNDS` | `P0026` |
| Posting to closed wallet | `ACCT_NOT_ACTIVE` | `P0022` (or `P0004`) |
| Wallet not found | `ACCT_NOT_FOUND` | `P0021` |
| KYC tier too low | `TIER_INSUFFICIENT` | `P0023` |
| Tier daily/monthly cap | `TIER_LIMIT_EXCEEDED` | (per-SP) |
| Active debit restraint | `DR_RESTRAINT_ACTIVE` | `P0025` |
| Active credit restraint | `CR_RESTRAINT_ACTIVE` | `P0029` |
| Group debit restraint | (was 500) | `P0025` (new — see US-9.18) |
| Duplicate reference | `DUPLICATE_REFERENCE` | `23505` |
| Lock timeout (PgBouncer waits) | `TIMEOUT` | `55P03` |
| Statement timeout | `TIMEOUT` | `57014` |
| Reversal window expired | (was missing) | `P0060` (new — US-3.6) |
| Treasury withdraw not found | `WD_NOT_FOUND` | `P0040` |
| Treasury withdraw completed | `WD_ALREADY_COMPLETED` | `P0041` |
| JWT missing/expired/bad sig | (no JWT before) | `E1001` |
| RBAC missing role | (no JWT before) | `E1006` |
| Validation failure (gin binding) | `INVALID_REQUEST` | `E4001` |
| Anything else (unwhitelisted) | `INTERNAL_ERROR` | `999999` |

When triaging a run, the canonical name is still recoverable from the
`errorMessage` prefix (`"INSUFFICIENT_FUNDS: balance 5 < required 10"`) — the
SQLSTATE is for client routing, the readable name is for humans.

## How to re-run

Local stack must be up + seeded:

```bash
docker compose up -d
psql … -f db/seeds/wallet_seed.sql                       # ~10k wallets
deploy/loadtest/k6.sh                                    # defaults: PEAK=300 DURATION=60
# or with peak override:
deploy/loadtest/k6.sh -e PEAK=500 -e DURATION=120
```

The driver script timestamps the report into this directory:

```
deploy/loadtest/reports/k6_<YYYYMMDD>_<HHMMSS>.md
```

A fresh run on the PR-39 branch should produce identical aggregates (latency,
throughput, % handled) to the pre-PR baselines on file (`k6_20260601_*.md`) —
only the **labels** under "Response codes" change as documented above.

## Sanity assertions to add for the first post-merge run

1. `outcome{code=00000}` does **not** appear — `00000` is a success marker,
   not an outcome label; success outcomes are `SUCCESS`/`DUPLICATE`/etc.
2. `outcome{code=999999}` count should be **0** under nominal load. Any
   non-zero count is an unwhitelisted error leaking — investigate via
   `trace_id` in the wallet-service log (`sql_state` will reveal the real
   cause).
3. `outcome{code=E1001}` and `outcome{code=E1006}` only appear when
   `JWT_ENABLED=true`. Default load test runs with JWT off, so these stay 0.
4. `checks_succeeded` `tx_status present` rate should remain 100% — confirms
   the 201 body still carries `data.transaction_status` (regression guard for
   the envelope change).

## Sibling artifact

The Postman collection (`services/wallet-service/postman/wallet-service.postman_collection.json`)
received the matching update — every success-path script now reads
`body.data.<field>` and error-path scripts read `body.errorCode`/`body.errorMessage`.
77 substitutions; JSON validates; see PR #39 commit log.
