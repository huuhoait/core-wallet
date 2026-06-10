# Outbox Event Envelope (US-7.4)

Canonical, versioned contract for every row in `WLT_OUTBOX` — so a downstream
consumer can **route, filter, and replay events without joining back to the
ledger**. The envelope is stamped uniformly by the DB trigger
`trg_outbox_envelope` (function `fn_outbox_envelope`, `db/export/schema.sql`),
which runs `BEFORE INSERT` after `trg_audit_cols`. Emitting SPs keep building
their own business payload and do **not** need to know this contract.

> 🇻🇳 Hợp đồng sự kiện chuẩn cho mọi dòng `WLT_OUTBOX`: consumer có thể định
> tuyến / replay mà không cần join lại ledger. Trigger DB tự đóng dấu envelope.

## Shape

A published message has three parts:

| Part | Source | Purpose |
|------|--------|---------|
| `payload.<business fields>` | the emitting SP | event-type-specific data (unchanged, stays at the payload root — backward compatible) |
| `payload.meta` | `fn_outbox_envelope` | the canonical metadata block (below) |
| `headers` | `fn_outbox_envelope` | broker-level routing/correlation |

### `payload.meta` (schema_version `v1`)

| Key | Type | Notes |
|-----|------|-------|
| `schema_version` | string | envelope contract version; mirrors `WLT_OUTBOX.event_version` (`v1`) |
| `event_type` | string | e.g. `wallet.transfer.posted.v1` |
| `aggregate_type` | string | `TRANSACTION` / `WITHDRAW` / `TRANSFER` / `TOPUP` / `MERCHANT_WITHDRAW` |
| `aggregate_id` | string | the aggregate's id (usually the `tran_internal_id`) |
| `partition_key` | string | Kafka partition key the relay uses |
| `reference` | string \| null | client idempotency / external reference — lifted from the business payload (`reference` \| `orig_reference` \| `ext_payout_ref`) |
| `tran_type` | string \| null | ledger tran-type code, mapped from `event_type` in one place in `fn_outbox_envelope` (e.g. `TOPUP`, `WDRAW`, `RVTRF`) |
| `channel` | string | originating channel — from the per-TX `audit.channel` GUC (via `CHANNEL`) |
| `actor` | string | who triggered it — from the per-TX `audit.actor` GUC (via `CREATED_BY`) |
| `occurred_at` | string | ISO-8601 UTC, ms precision — the row's `created_at` |
| `trace_id` | string \| null | full W3C `traceparent` (continues the distributed trace, US-9.5) |

### `headers`

`traceparent` (when present) plus `schema_version`, `event_type`, and
`content_type: application/json` for broker-level routing without deserializing
the body.

## Example

```json
{
  "tran_internal_id": 6554001,
  "reference": "TOPUP-abc-123",
  "acct_no": "97010000362701",
  "amount": 50000,
  "ccy": "VND",
  "value_date": "2026-06-10",
  "meta": {
    "schema_version": "v1",
    "event_type": "wallet.topup.posted.v1",
    "aggregate_type": "TRANSACTION",
    "aggregate_id": "6554001",
    "partition_key": "97010000362701",
    "reference": "TOPUP-abc-123",
    "tran_type": "TOPUP",
    "channel": "MOBILE",
    "actor": "ops.bob",
    "occurred_at": "2026-06-10T03:13:31.145Z",
    "trace_id": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  }
}
```

## event_type → tran_type map

Maintained centrally in `fn_outbox_envelope` (not duplicated across emitters).
If the `TRAN_TYPE` codes are ever renamed (US-9.15), update the map too.

| event_type | tran_type |
|------------|-----------|
| `wallet.topup.posted.v1` | `TOPUP` |
| `wallet.topup.reversed.v1` | `RVTPUP` |
| `wallet.transfer.posted.v1` | `TRFOUT` |
| `wallet.transfer.reversed.v1` | `RVTRF` |
| `wallet.withdraw.posted.v1` / `.acked` / `.disbursing` / `.completed` | `WDRAW` |
| `wallet.withdraw.reversed.v1` | `RVWD` |
| `wallet.fee.charged.v1` | `FEECHG` |
| `wallet.fee.reversed.v1` | `RVFEE` |
| `wallet.merchant.deposit.posted.v1` | `MERCHDEP` |
| `wallet.merchant_withdraw.posted.v1` | `MERCHWD` |
| `wallet.merchant_withdraw.reversed.v1` | `RVMWD` |

## Versioning

`schema_version` is bumped (`v2`, …) only on a **breaking** envelope change
(removing/renaming a `meta` key). Additive keys stay `v1`. The relay (US-7.2)
and consumers (US-7.3) branch on `meta.schema_version`.

## Tests

`db/tests/wallet_outbox_envelope_test.sql` — end-to-end (a posted top-up carries
the full meta + enriched headers, business fields stay top-level) and the
emitter-agnostic path (reference lifted from `orig_reference`, tran_type mapped,
headers built even when the SP passed none).
