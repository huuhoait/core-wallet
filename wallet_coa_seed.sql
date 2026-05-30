-- =============================================================================
-- wallet_coa_seed.sql — Standard Chart of Accounts (GL) for the Wallet ledger
-- =============================================================================
-- Target:    PostgreSQL 17+
-- Scope:     Independent e-wallet (NĐ 52/2024, TT 23/2019 NHNN) — VND, Y1
-- Companion: wallet_gl_coa_spec.md  (accounting spec + posting rules)
-- Depends:   FM_GL_MAST, WLT_GL_MAP, WLT_ACCT_TYPE  (wallet_schema.sql §11)
--
-- This file is the CANONICAL full chart of accounts. It SUPERSEDES the minimal
-- 14-account seed embedded in wallet_schema.sql §11 by ADDING the missing
-- account groups (receivables, prepaid float, clearing/suspense, settlement
-- payables, dormant balances, provisions, financial income, expenses).
--
-- Idempotency:
--   - All INSERTs use ON CONFLICT (GL_CODE) DO NOTHING → safe to re-run, and
--     safe to run on a DB that already has the minimal set (existing rows skip).
--   - Parent links are set in a second pass via UPDATE (avoids FK ordering).
--
-- Numbering scheme  LLL.GG.SSS  (class . group . sub-account)
--   1xx = ASSETS        (GL_CODE_TYPE 'A', BSPL 'B')
--   2xx = LIABILITIES   (GL_CODE_TYPE 'L', BSPL 'B')
--   4xx = INCOME        (GL_CODE_TYPE 'I', BSPL 'P')
--   5xx = EXPENSES      (GL_CODE_TYPE 'E', BSPL 'P')
--
-- Core invariant (SBV compliance, enforced by daily reconciliation, see spec §5):
--   Σ(101.01.* TKĐBTT) + Σ(101.02.* nostro)  ≥  Σ(201.01.* + 201.02.*)
--   i.e. real money in segregated bank accounts must cover real wallet balances.
--   Promotional balance (201.03.*) is NOT escrow-backed (funded by 502.01).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- §1. ASSETS (1xx)
-- -----------------------------------------------------------------------------
INSERT INTO FM_GL_MAST (GL_CODE, GL_CODE_DESC, GL_CODE_TYPE, BSPL_TYPE, GL_TYPE) VALUES
  -- 101 Cash & settlement at banks --------------------------------------------
  ('101',         'Cash & equivalents (parent)',                'A','B','CASH'),
  ('101.01',      'Settlement accounts — TKĐBTT (parent)',      'A','B','CASH'),
  ('101.01.001',  'TKĐBTT — Partner Bank A (escrow)',           'A','B','TKDBTT'),
  ('101.01.002',  'TKĐBTT — Partner Bank B (escrow)',           'A','B','TKDBTT'),
  ('101.02',      'Nostro accounts (parent)',                   'A','B','CASH'),
  ('101.02.001',  'Nostro @ Partner Bank — TKĐBTT',             'A','B','NOSTRO'),
  ('101.03',      'Operating bank accounts (parent)',           'A','B','CASH'),
  ('101.03.001',  'Operating account — Bank A',                 'A','B','OPER'),
  -- 102 Receivables -----------------------------------------------------------
  ('102',         'Receivables (parent)',                       'A','B','RECV'),
  ('102.01',      'Cash-in receivable (parent)',                'A','B','RECV'),
  ('102.01.001',  'Cash-in receivable — NAPAS / IBFT',          'A','B','RECV'),
  ('102.01.002',  'Cash-in receivable — Card (Visa/MC/JCB)',    'A','B','RECV'),
  ('102.01.003',  'Cash-in receivable — Bank-linked account',   'A','B','RECV'),
  ('102.02',      'Partner / biller receivable (parent)',       'A','B','RECV'),
  ('102.02.001',  'Receivable — biller settlement',             'A','B','RECV'),
  -- 103 Prepaid & advances ----------------------------------------------------
  ('103',         'Prepaid & advances (parent)',                'A','B','PREPAID'),
  ('103.01',      'Prepaid float (parent)',                     'A','B','PREPAID'),
  ('103.01.001',  'Prepaid float to biller / partner',          'A','B','PREPAID'),
  -- 109 Clearing & suspense ---------------------------------------------------
  ('109',         'Clearing & suspense (parent)',               'A','B','CLEAR'),
  ('109.01',      'Cash-in clearing (parent)',                  'A','B','CLEAR'),
  ('109.01.001',  'Cash-in clearing',                           'A','B','CLEAR'),
  ('109.02',      'Cash-out clearing (parent)',                 'A','B','CLEAR'),
  ('109.02.001',  'Cash-out / disbursement clearing',           'A','B','CLEAR'),
  ('109.03',      'Payment clearing (parent)',                  'A','B','CLEAR'),
  ('109.03.001',  'Payment & settlement clearing',              'A','B','CLEAR'),
  ('109.04',      'Suspense (parent)',                          'A','B','SUSP'),
  ('109.04.001',  'Reversal / failed-txn suspense',             'A','B','SUSP'),
  ('109.04.002',  'Unidentified receipts',                      'A','B','SUSP'),
  ('109.04.009',  'Reconciliation difference',                  'A','B','SUSP')
ON CONFLICT (GL_CODE) DO NOTHING;

-- -----------------------------------------------------------------------------
-- §2. LIABILITIES (2xx)
-- -----------------------------------------------------------------------------
INSERT INTO FM_GL_MAST (GL_CODE, GL_CODE_DESC, GL_CODE_TYPE, BSPL_TYPE, GL_TYPE) VALUES
  -- 201 Customer / merchant wallet liabilities --------------------------------
  ('201',         'Customer liabilities (parent)',              'L','B','LIAB'),
  ('201.01',      'Customer wallets (parent)',                  'L','B','LIAB'),
  ('201.01.001',  'Customer Wallet — Consumer',                 'L','B','LIAB'),
  ('201.02',      'Merchant wallets (parent)',                  'L','B','LIAB'),
  ('201.02.001',  'Merchant Wallet',                            'L','B','LIAB'),
  ('201.03',      'Promotional balance (parent, NOT escrow-backed)','L','B','PROMO'),
  ('201.03.001',  'Promotional / bonus wallet balance',         'L','B','PROMO'),
  -- 202 Settlement payables ---------------------------------------------------
  ('202',         'Settlement payables (parent)',               'L','B','SETTLE'),
  ('202.01',      'Merchant settlement payable (parent)',       'L','B','SETTLE'),
  ('202.01.001',  'Payable to merchant — settlement',           'L','B','SETTLE'),
  ('202.02',      'Biller / partner payable (parent)',          'L','B','SETTLE'),
  ('202.02.001',  'Payable to biller / service partner',        'L','B','SETTLE'),
  -- 203 Tax payable -----------------------------------------------------------
  ('203',         'Tax payable (parent)',                       'L','B','TAX'),
  ('203.01',      'VAT output payable',                         'L','B','TAX'),
  -- 204 Dormant / unclaimed ---------------------------------------------------
  ('204',         'Dormant / unclaimed balances (parent)',      'L','B','LIAB'),
  ('204.01',      'Dormant balances (parent)',                  'L','B','LIAB'),
  ('204.01.001',  'Dormant wallet liability',                   'L','B','LIAB'),
  -- 205 Provisions ------------------------------------------------------------
  ('205',         'Provisions (parent)',                        'L','B','PROV'),
  ('205.01',      'Promotion provision (parent)',               'L','B','PROV'),
  ('205.01.001',  'Cashback / promotion payable reserve',       'L','B','PROV')
ON CONFLICT (GL_CODE) DO NOTHING;

-- -----------------------------------------------------------------------------
-- §3. INCOME (4xx)
-- -----------------------------------------------------------------------------
INSERT INTO FM_GL_MAST (GL_CODE, GL_CODE_DESC, GL_CODE_TYPE, BSPL_TYPE, GL_TYPE) VALUES
  ('401',         'Fee revenue (parent)',                       'I','P','REV'),
  ('401.01',      'Transfer/withdraw fee revenue',              'I','P','REV'),
  ('401.02',      'Merchant withdraw fee revenue',              'I','P','REV'),
  ('401.03',      'Merchant discount rate (MDR)',               'I','P','REV'),
  ('401.04',      'Bill-payment / top-up commission income',    'I','P','COMM'),
  ('402',         'Financial income (parent)',                  'I','P','INTINC'),
  ('402.01',      'Float interest income on TKĐBTT',            'I','P','INTINC')
ON CONFLICT (GL_CODE) DO NOTHING;

-- -----------------------------------------------------------------------------
-- §4. EXPENSES (5xx)
-- -----------------------------------------------------------------------------
INSERT INTO FM_GL_MAST (GL_CODE, GL_CODE_DESC, GL_CODE_TYPE, BSPL_TYPE, GL_TYPE) VALUES
  ('501',         'Channel & processing cost (parent)',         'E','P','EXP'),
  ('501.01',      'Bank / channel fee (cash-in & cash-out)',    'E','P','EXP'),
  ('501.02',      'Card scheme / switching fee (NAPAS/Visa/MC)','E','P','EXP'),
  ('502',         'Marketing & partner cost (parent)',          'E','P','EXP'),
  ('502.01',      'Cashback / promotion expense',               'E','P','EXP'),
  ('502.02',      'Partner commission expense',                 'E','P','EXP')
ON CONFLICT (GL_CODE) DO NOTHING;

-- -----------------------------------------------------------------------------
-- §5. Parent links (CONTROL_GL_CODE) — second pass, idempotent
-- -----------------------------------------------------------------------------
-- Assets
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='101'        WHERE GL_CODE IN ('101.01','101.02','101.03');
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='101.01'     WHERE GL_CODE IN ('101.01.001','101.01.002');
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='101.02'     WHERE GL_CODE='101.02.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='101.03'     WHERE GL_CODE='101.03.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='102'        WHERE GL_CODE IN ('102.01','102.02');
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='102.01'     WHERE GL_CODE IN ('102.01.001','102.01.002','102.01.003');
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='102.02'     WHERE GL_CODE='102.02.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='103'        WHERE GL_CODE='103.01';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='103.01'     WHERE GL_CODE='103.01.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='109'        WHERE GL_CODE IN ('109.01','109.02','109.03','109.04');
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='109.01'     WHERE GL_CODE='109.01.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='109.02'     WHERE GL_CODE='109.02.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='109.03'     WHERE GL_CODE='109.03.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='109.04'     WHERE GL_CODE IN ('109.04.001','109.04.002','109.04.009');
-- Liabilities
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='201'        WHERE GL_CODE IN ('201.01','201.02','201.03');
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='201.01'     WHERE GL_CODE='201.01.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='201.02'     WHERE GL_CODE='201.02.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='201.03'     WHERE GL_CODE='201.03.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='202'        WHERE GL_CODE IN ('202.01','202.02');
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='202.01'     WHERE GL_CODE='202.01.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='202.02'     WHERE GL_CODE='202.02.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='203'        WHERE GL_CODE='203.01';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='204'        WHERE GL_CODE='204.01';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='204.01'     WHERE GL_CODE='204.01.001';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='205'        WHERE GL_CODE='205.01';
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='205.01'     WHERE GL_CODE='205.01.001';
-- Income
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='401'        WHERE GL_CODE IN ('401.01','401.02','401.03','401.04');
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='402'        WHERE GL_CODE='402.01';
-- Expenses
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='501'        WHERE GL_CODE IN ('501.01','501.02');
UPDATE FM_GL_MAST SET CONTROL_GL_CODE='502'        WHERE GL_CODE IN ('502.01','502.02');

-- -----------------------------------------------------------------------------
-- §6. Wallet event → GL mapping additions (forward-looking, optional)
-- -----------------------------------------------------------------------------
-- These rows let the posting engine resolve GL codes for events that are part
-- of the standard COA but not yet wired into a stored procedure. Safe to keep:
-- the engine looks up by exact (ACCT_TYPE, EVENT_TYPE), so unused rows are inert.
INSERT INTO WLT_GL_MAP (ACCT_TYPE, EVENT_TYPE, GL_CODE, GL_DESC) VALUES
  ('CONSUMER', 'PROMO_CR',     '201.03.001', 'Promotional balance credit'),
  ('CONSUMER', 'PROMO_EXP_DR', '502.01',     'Cashback / promotion expense'),
  ('CONSUMER', 'PAY_CLR',      '109.03.001', 'Payment & settlement clearing'),
  ('CONSUMER', 'CASHIN_CLR',   '109.01.001', 'Cash-in clearing'),
  ('CONSUMER', 'CASHOUT_CLR',  '109.02.001', 'Cash-out clearing'),
  ('CONSUMER', 'DORMANT_CR',   '204.01.001', 'Dormant wallet liability'),
  ('MERCHANT', 'SETTLE_CR',    '202.01.001', 'Payable to merchant — settlement'),
  ('MERCHANT', 'PAY_CLR',      '109.03.001', 'Payment & settlement clearing')
ON CONFLICT (ACCT_TYPE, EVENT_TYPE) DO NOTHING;

COMMIT;

-- =============================================================================
-- VERIFICATION (run manually after apply)
-- =============================================================================
-- Full chart, indented by depth:
--   SELECT repeat('  ', (length(GL_CODE)-length(replace(GL_CODE,'.','')))) || GL_CODE AS code,
--          GL_CODE_DESC, GL_CODE_TYPE, GL_TYPE
--     FROM FM_GL_MAST ORDER BY GL_CODE;
--
-- Every non-root account must have a valid parent (expect 0 rows):
--   SELECT GL_CODE FROM FM_GL_MAST
--    WHERE GL_CODE LIKE '%.%' AND CONTROL_GL_CODE IS NULL;
--
-- Class balance sanity (each class maps to one type):
--   SELECT left(GL_CODE,1) AS class, GL_CODE_TYPE, count(*)
--     FROM FM_GL_MAST GROUP BY 1,2 ORDER BY 1;
-- =============================================================================
