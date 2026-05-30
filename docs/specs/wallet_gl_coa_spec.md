# Wallet GL — Standard Chart of Accounts & Accounting Spec

**Version:** 1.0 (2026-05-29)
**Scope:** Independent e-wallet (NĐ 52/2024, TT 23/2019 NHNN) — VND, Year 1
**Applies to:** `FM_GL_MAST`, `WLT_TRAN_DEF`, `WLT_GL_MAP`, `WLT_ACCT_TYPE`, `WLT_GL_BATCH`
**Seed:** [wallet_coa_seed.sql](../wallet_coa_seed.sql) · **Exports:** [wallet_coa.csv](wallet_coa.csv) · [wallet_coa.json](wallet_coa.json)
**Status:** Applied to `wallet` DB (62 accounts). Extends the 14-account minimal set in [wallet_schema.sql](../wallet_schema.sql) §11.

---

## 1. Accounting principles (non-negotiable)

| # | Principle | Implication in this ledger |
|---|-----------|----------------------------|
| 1 | Customer wallet balance is a **liability** of WalletCo, not revenue | `201.01.*`, `201.02.*` are class-`L` accounts |
| 2 | **Double-entry**: every operation balances Σ DR = Σ CR | Posting engine writes ≥2 `WLT_GL_BATCH` legs per `TFR_INTERNAL_KEY` |
| 3 | **TKĐBTT (escrow) ≥ total real wallet balance** (SBV) | Invariant: `Σ(101.01.*)+Σ(101.02.*) ≥ Σ(201.01.*+201.02.*)` |
| 4 | Money "in transit" never nets directly — it parks in **clearing/suspense** | `109.*` accounts; must drain to 0 each EOD |
| 5 | Promotional money is **not escrow-backed** | `201.03.*` funded by expense `502.01`, excluded from invariant #3 |
| 6 | Wallet GL ≠ corporate ledger | Map to TT200 at consolidation — see §6 |

> The system uses an **internal-nostro bridge** model: posting SPs settle against `101.02.001` (internal nostro) atomically; the Treasury Service moves real money in/out of the segregated `101.01.*` TKĐBTT accounts and reconciles T+1 via MT940. The `109.*` clearing accounts make the in-transit leg explicit when channel settlement is decoupled from wallet credit.

---

## 2. Chart of accounts (62 accounts)

Numbering: `LLL.GG.SSS` = class . group . sub-account. Type: A=Asset, L=Liability, I=Income, E=Expense. BSPL: B=Balance sheet, P=P&L.

### 1xx — ASSETS
| Code | Account | Type | GL_TYPE |
|------|---------|:----:|---------|
| 101 | Cash & equivalents *(parent)* | A | CASH |
| 101.01 | Settlement accounts — TKĐBTT *(parent)* | A | CASH |
| 101.01.001 | TKĐBTT — Partner Bank A (escrow) | A | TKDBTT |
| 101.01.002 | TKĐBTT — Partner Bank B (escrow) | A | TKDBTT |
| 101.02 | Nostro accounts *(parent)* | A | CASH |
| 101.02.001 | Nostro @ Partner Bank — TKĐBTT *(internal bridge)* | A | NOSTRO |
| 101.03 | Operating bank accounts *(parent)* | A | CASH |
| 101.03.001 | Operating account — Bank A | A | OPER |
| 102 | Receivables *(parent)* | A | RECV |
| 102.01 | Cash-in receivable *(parent)* | A | RECV |
| 102.01.001 | Cash-in receivable — NAPAS / IBFT | A | RECV |
| 102.01.002 | Cash-in receivable — Card (Visa/MC/JCB) | A | RECV |
| 102.01.003 | Cash-in receivable — Bank-linked account | A | RECV |
| 102.02 | Partner / biller receivable *(parent)* | A | RECV |
| 102.02.001 | Receivable — biller settlement | A | RECV |
| 103 | Prepaid & advances *(parent)* | A | PREPAID |
| 103.01 | Prepaid float *(parent)* | A | PREPAID |
| 103.01.001 | Prepaid float to biller / partner | A | PREPAID |
| 109 | Clearing & suspense *(parent)* | A | CLEAR |
| 109.01.001 | Cash-in clearing | A | CLEAR |
| 109.02.001 | Cash-out / disbursement clearing | A | CLEAR |
| 109.03.001 | Payment & settlement clearing | A | CLEAR |
| 109.04.001 | Reversal / failed-txn suspense | A | SUSP |
| 109.04.002 | Unidentified receipts | A | SUSP |
| 109.04.009 | Reconciliation difference | A | SUSP |

### 2xx — LIABILITIES
| Code | Account | Type | GL_TYPE |
|------|---------|:----:|---------|
| 201 | Customer liabilities *(parent)* | L | LIAB |
| 201.01.001 | Customer Wallet — Consumer | L | LIAB |
| 201.02.001 | Merchant Wallet | L | LIAB |
| 201.03.001 | Promotional / bonus balance *(not escrow-backed)* | L | PROMO |
| 202.01.001 | Payable to merchant — settlement | L | SETTLE |
| 202.02.001 | Payable to biller / service partner | L | SETTLE |
| 203.01 | VAT output payable | L | TAX |
| 204.01.001 | Dormant wallet liability | L | LIAB |
| 205.01.001 | Cashback / promotion payable reserve | L | PROV |

*(parent rows 201.01, 201.02, 201.03, 202, 202.01, 202.02, 203, 204, 204.01, 205, 205.01 also exist)*

### 4xx — INCOME
| Code | Account | Type | GL_TYPE |
|------|---------|:----:|---------|
| 401.01 | Transfer/withdraw fee revenue | I | REV |
| 401.02 | Merchant withdraw fee revenue | I | REV |
| 401.03 | Merchant discount rate (MDR) | I | REV |
| 401.04 | Bill-payment / top-up commission income | I | COMM |
| 402.01 | Float interest income on TKĐBTT | I | INTINC |

### 5xx — EXPENSES
| Code | Account | Type | GL_TYPE |
|------|---------|:----:|---------|
| 501.01 | Bank / channel fee (cash-in & cash-out) | E | EXP |
| 501.02 | Card scheme / switching fee (NAPAS/Visa/MC) | E | EXP |
| 502.01 | Cashback / promotion expense | E | EXP |
| 502.02 | Partner commission expense | E | EXP |

---

## 3. Posting rules per transaction type

Legs reference `WLT_TRAN_DEF` (`CONTRA_GL_CODE`, `FEE_GL_CODE`, `VAT_GL_CODE`) and `WLT_ACCT_TYPE.GL_CODE_LIAB`. Each block = one `TFR_INTERNAL_KEY`.

**TOPUP — top-up from bank** (`WLT_TRAN_DEF['TOPUP']`)
```
DR 101.02.001 Internal nostro      amount      (CONTRA_GL_CODE)
CR 201.01.001 Consumer wallet       amount      (GL_CODE_LIAB)
```

**DEPOSIT (agent) — cash-in via agent, fee charged to customer**
```
CR 201.01.001 Customer wallet       +amount
DR 201.01.001 Agent collateral      -amount     (agent wallet, same GL)
DR 201.01.001 Customer wallet (fee) -fee_gross
CR 401.01     Fee revenue net       +fee_net
CR 203.01     VAT output payable    +vat
```

**WDRAW — withdraw to bank** (PERCENT 0.1%, min 11k, max 55k; VAT 10%)
```
DR 201.01.001 Customer wallet       -amount
CR 101.02.001 Internal nostro       +amount     (CONTRA_GL_CODE → Treasury disburses from 101.01.*)
DR 201.01.001 Customer wallet (fee) -fee_gross
CR 401.01     Fee revenue net       +fee_net
CR 203.01     VAT output payable    +vat
```

**TRFOUT/TRFIN — P2P wallet→wallet** (FIXED fee 5,500; VAT 10%)
```
DR 201.01.001 Wallet A              -amount
CR 201.01.001 Wallet B              +amount     (escrow unchanged — money stays in system)
DR 201.01.001 Wallet A (fee)        -fee_gross
CR 401.01     Fee revenue net       +fee_net
CR 203.01     VAT output payable    +vat
```

**MERCHWD — merchant settlement withdraw** (PERCENT 0.05%, min 22k, max 110k)
```
DR 201.02.001 Merchant wallet       -amount
CR 101.02.001 Internal nostro       +amount
DR 201.02.001 Merchant wallet (fee) -fee_gross
CR 401.02     Merchant WD fee       +fee_net
CR 203.01     VAT output payable    +vat
```

**RV* — reversals** mirror the original legs with opposite `CR_DR_MAINT_IND`; a refund reverses fee + VAT too.

**PROMO credit — promotional/cashback grant** *(forward-looking; map rows in `WLT_GL_MAP`)*
```
DR 502.01     Promotion expense     amount
CR 201.03.001 Promotional balance   amount      (NOT escrow-backed)
```

**Bill payment to biller** *(when wired)*
```
DR 201.01.001 Customer wallet       -amount
CR 109.03.001 Payment clearing      +amount     (drains to 202.02.001 / 101.01.* on settlement)
CR 401.04     Commission income     +commission
```

---

## 4. `WLT_GL_MAP` event → GL resolution

Wired today (in stored procedures):

| ACCT_TYPE | EVENT_TYPE | GL_CODE |
|-----------|-----------|---------|
| CONSUMER | LIABILITY / TOPUP_DR / WITHDRAW_CR / FEE_CR / VAT_CR | 201.01.001 / 101.02.001 / 101.02.001 / 401.01 / 203.01 |
| MERCHANT | LIABILITY / WITHDRAW_CR / MDR_CR / FEE_CR / VAT_CR | 201.02.001 / 101.02.001 / 401.03 / 401.02 / 203.01 |

Added by this COA (inert until referenced by an SP): `PROMO_CR`→201.03.001, `PROMO_EXP_DR`→502.01, `PAY_CLR`→109.03.001, `CASHIN_CLR`→109.01.001, `CASHOUT_CLR`→109.02.001, `DORMANT_CR`→204.01.001, `SETTLE_CR`→202.01.001.

---

## 5. Reconciliation controls (daily EOD)

| # | Control | Rule | On breach |
|---|---------|------|-----------|
| C1 | **Escrow coverage (SBV)** | `Σ(101.01.*)+Σ(101.02.*) ≥ Σ(201.01.*+201.02.*)` | Block payouts; alert Treasury |
| C2 | **Ledger balance** | `Σ DR = Σ CR` across all `WLT_GL_BATCH` | Halt posting; investigate |
| C3 | **Clearing drains** | `109.01/02/03.* = 0` at EOD | Residual = stuck txn → ops queue |
| C4 | **Bank reconciliation** | ledger `101.01.*` = MT940 statement | Diff → park in `109.04.009`, resolve |
| C5 | **Promo segregation** | `201.03.*` excluded from C1 | Misclassification audit |

```sql
-- C1 escrow coverage
SELECT (SELECT COALESCE(SUM(ACTUAL_BAL),0) FROM WLT_ACCT a JOIN WLT_ACCT_TYPE t USING(ACCT_TYPE)
        WHERE t.GL_CODE_LIAB IN ('201.01.001','201.02.001')) AS wallet_liability;
-- compare against TKĐBTT + nostro balances from WLT_NOSTRO_BAL / FM_NOS_VOS
```

---

## 6. Mapping to corporate ledger (TT200)

| Wallet GL | TT200 |
|-----------|-------|
| 101.01.*, 101.02.*, 101.03.* | 1121 — Tiền gửi NH (tách TK ĐBTT) |
| 102.* | 131 / 138 — Phải thu |
| 109.* | 138 / 338 — Phải thu/phải trả khác (treo) |
| 201.* | 3388 / 344 — Phải trả số dư ví |
| 202.* | 331 — Phải trả người bán |
| 203.01 | 33311 — VAT đầu ra |
| 204.* | 338 — Phải trả khác |
| 205.* | 352 — Dự phòng phải trả |
| 401.*, 402.* | 511 / 515 |
| 501.*, 502.* | 627 / 641 / 642 |

---

## 7. Operational notes

- **Adding a partner bank escrow:** insert `101.01.00n` (parent `101.01`), then register in `FM_NOS_VOS` (ACCT_TYPE=`TKDBTT`) and `WLT_NOSTRO_LINK` (PURPOSE=`TKDBTT`, REG_NHNN_CODE).
- **Re-running the seed is safe** — `ON CONFLICT DO NOTHING` on `GL_CODE` and `(ACCT_TYPE,EVENT_TYPE)`.
- **Do not delete** `101.02.001`, `201.01.001`, `201.02.001`, `203.01`, `401.01/02/03` — referenced by stored procedures and `WLT_TRAN_DEF`.
- New `GL_TYPE` values introduced: `TKDBTT, OPER, RECV, PREPAID, CLEAR, SUSP, PROMO, SETTLE, PROV, COMM, INTINC, EXP`.

---

## 8. Transaction-type catalogue (VN convention)

`TRAN_TYPE` widened **VARCHAR(8) → VARCHAR(10)** on `WLT_TRAN_DEF` (PK, `FEE_TRAN_TYPE`, `REVERSAL_TRAN_TYPE`) and `WLT_TRAN_HIST` (cascades to all partitions). Migration: [wallet_tran_type_ext.sql](../wallet_tran_type_ext.sql). Total catalogue = **35 types** (16 original + 19 added).

Wallet GL `201.0x.001` = customer/merchant liability from `WLT_ACCT_TYPE.GL_CODE_LIAB`.

| TRAN_TYPE | Nghiệp vụ | Ví | Contra / fee GL | Phí + VAT |
|-----------|-----------|:--:|-----------------|-----------|
| **TOPUP** | Nạp ví từ NH | CR | `101.02.001` | – |
| **DEPOSIT** | Nạp qua đại lý | CR | ví đại lý (`201.01.001`) | FIXED 5.500 → `401.01` + `203.01` (`FEEDEP`) |
| **WDRAW** | Rút về NH | DR | `101.02.001` | 0.1% → `401.01` + `203.01` |
| **TRFOUT/TRFIN** | Chuyển ví↔ví | DR/CR | ví đối ứng | FIXED 5.500 → `401.01` + `203.01` |
| **PAYMENT** | Thanh toán QR/merchant | DR | `109.03.001` clearing | – (MDR thu ở SETTLE) |
| **BILLPAY** | Thanh toán hóa đơn | DR | `109.03.001` clearing | – (hoa hồng `401.04` ở settle) |
| **AIRTIME** | Nạp ĐT / data | DR | `109.03.001` clearing | – |
| **SETTLE** | Quyết toán merchant | CR | `109.03.001` clearing | MDR 1.1% → `401.03` + `203.01` (`MDRFEE`) |
| **MERCHWD** | Merchant rút settlement | DR | `101.02.001` | 0.05% → `401.02` + `203.01` |
| **CASHBACK** | Hoàn tiền khuyến mãi | CR | `502.01` expense | – (vào ví promo `201.03.001`) |
| **REFUND** | Hoàn tiền giao dịch | CR | `109.03.001` clearing | – |
| **ADJCR / ADJDR** | Điều chỉnh ops (duyệt tay) | CR/DR | `109.04.001` suspense | – (`AUTO_APPROVAL='N'`) |
| **SWEEPO/SWEEPI** | Gom số dư shard merchant | DR/CR | `201.02.001` | – |
| **FEE\*** | Leg phí (`FEETRF/FEEWD/FEEMW/FEEDEP/MDRFEE`) | DR | `401.0x` | – |
| **RV\*** | Đảo giao dịch (mirror leg gốc) | ngược | theo bản gốc | refund cả phí |

### Posting mới cần SP (GL wiring là contract)

**PAYMENT → SETTLE (QR/merchant, MDR thu tại quyết toán):**
```
PAYMENT  : DR 201.01.001 ví KH        -amount  →  CR 109.03.001 payment clearing
SETTLE   : DR 109.03.001 clearing     -amount  →  CR 201.02.001 ví merchant  (net)
MDRFEE   : DR 201.02.001 ví merchant  -mdr     →  CR 401.03 MDR + CR 203.01 VAT
```

**BILLPAY / AIRTIME (tiền ra khỏi hệ thống tới biller):**
```
BILLPAY  : DR 201.01.001 ví KH  →  CR 109.03.001 clearing
settle   : DR 109.03.001        →  CR 101.02.001 nostro (trả biller) + CR 401.04 hoa hồng
```

**CASHBACK (tiền marketing, KHÔNG escrow-backed):**
```
CASHBACK : DR 502.01 chi phí KM  →  CR 201.03.001 ví khuyến mãi
```

**ADJCR/ADJDR (điều chỉnh thủ công — luôn treo qua suspense, duyệt tay):**
```
ADJCR    : DR 109.04.001 suspense  →  CR 201.01.001 ví KH
ADJDR    : DR 201.01.001 ví KH     →  CR 109.04.001 suspense
```

> ⚠️ MDR rate `0.011` (1.1%) và phí DEPOSIT 5.500 là **giá trị mẫu, tunable per product policy** — chỉnh trong `WLT_TRAN_DEF` không cần đổi schema.
> ⚠️ Các loại PAYMENT/SETTLE/BILLPAY/AIRTIME/CASHBACK/REFUND/ADJ* mới ở mức **config**; cần viết stored procedure để thực thi (engine hiện chỉ wired TOPUP/WDRAW/TRF*/MERCHWD/SWEEP*).
