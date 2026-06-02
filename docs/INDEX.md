# Documentation Index / Mục lục tài liệu

Catalogue of all design documents. Status of the features they describe lives in
[../USER_STORIES.md](../USER_STORIES.md).

> 🇻🇳 Mục lục toàn bộ tài liệu thiết kế. Trạng thái triển khai từng tính năng xem
> tại [../USER_STORIES.md](../USER_STORIES.md).

## High-Level Design — `hld/`

| Document | Description |
|----------|-------------|
| [hld/wallet_HLD.md](hld/wallet_HLD.md) | Master HLD: objectives & scope, stakeholders, system context, NFRs, fee/VAT, PII (§8.3), data lifecycle (§9a), accounting ops (§9b), outbox + withdraw tracking. |
| [hld/wallet_HLD_20tps.md](hld/wallet_HLD_20tps.md) | Reduced-footprint HLD variant sized for ~20 TPS. |

## Detailed Low-Level Design — `dld/`

| Document | Description |
|----------|-------------|
| [dld/wallet_DLD.md](dld/wallet_DLD.md) | Table-by-table schema, posting algorithms, lock ordering, partitioning, audit/outbox internals. |

## Feature & domain specs — `specs/`

| Document | Description |
|----------|-------------|
| [specs/finance_transaction.md](specs/finance_transaction.md) | Transaction flows + API specs: top-up, deposit, withdraw, merchant withdraw, transfer, reversal, history. |
| [specs/wallet_onboarding.md](specs/wallet_onboarding.md) | Onboarding & wallet-opening flow, KYC tiers, state machines, acceptance criteria. |
| [specs/error_management.md](specs/error_management.md) | Error taxonomy, codes, and handling strategy. |
| [specs/eod.md](specs/eod.md) | End-of-Day & GL accounting cutoff: the two closes (`run_eod` / `run_gl_close`), tasks T1–T7, write-freeze, the Go scheduler, and **dangerous DB-config / scheduler-config updates** (`WLT_GL_CONFIG.cutoff_time` ↔ `EOD_GL_CUTOFF` drift). |
| [specs/wallet_gl_coa_spec.md](specs/wallet_gl_coa_spec.md) | GL chart-of-accounts specification (source for `db/seeds/coa/`). |
| [specs/t24_transaction_posting.md](specs/t24_transaction_posting.md) | T24 core-banking transaction-posting reference. |
| [specs/k6_sweep.md](specs/k6_sweep.md) | k6 load-test sweep results / notes. |

## Where the implementation lives / Nơi chứa phần triển khai

| Concern | Location |
|---------|----------|
| Schema + procedures (consolidated DDL) | [`../db/export/schema.sql`](../db/export/schema.sql) |
| Monthly partitions | [`../db/export/partitions.sql`](../db/export/partitions.sql) |
| Reference / master seed | [`../db/export/seed.sql`](../db/export/seed.sql) |
| Load-test & demo fixtures | [`../db/seeds/`](../db/seeds/) |
| SQL test suites | [`../db/tests/`](../db/tests/) |
| Go service | [`../services/wallet-service/`](../services/wallet-service/) |
| Deploy (docker, loadtest) | [`../deploy/`](../deploy/) |
