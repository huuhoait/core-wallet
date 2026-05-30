-- =============================================================================
-- wallet_tran_type_ext.sql — Widen TRAN_TYPE to VARCHAR(10) + VN-convention
--                            transaction-type catalogue wired to the COA
-- =============================================================================
-- Target:    PostgreSQL 17+
-- Depends:   wallet_schema.sql (WLT_TRAN_DEF, WLT_TRAN_HIST), wallet_coa_seed.sql (GL)
-- Companion: claudedocs/wallet_gl_coa_spec.md
--
-- Part A — widen the TRAN_TYPE field 8 → 10 chars (metadata-only, no rewrite).
--          Covers WLT_TRAN_DEF (PK + FEE_TRAN_TYPE + REVERSAL_TRAN_TYPE) and the
--          partitioned WLT_TRAN_HIST (parent ALTER cascades to all partitions).
-- Part B — add standard Vietnamese e-wallet transaction types, mapped to the
--          chart of accounts. New legs reference existing GL codes only.
--
-- Idempotent: ALTERs are no-ops if already widened; INSERTs ON CONFLICT DO NOTHING.
--
-- NOTE: rows added here are REFERENCE/CONFIG data. The posting flows for
--       PAYMENT / BILLPAY / AIRTIME / SETTLE / CASHBACK / REFUND / ADJ* still
--       require a stored procedure to execute them (see spec §7). The GL wiring
--       below is the contract those SPs must follow.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- PART A — widen TRAN_TYPE field to VARCHAR(10)
-- -----------------------------------------------------------------------------
ALTER TABLE WLT_TRAN_DEF  ALTER COLUMN TRAN_TYPE          TYPE VARCHAR(10);
ALTER TABLE WLT_TRAN_DEF  ALTER COLUMN REVERSAL_TRAN_TYPE TYPE VARCHAR(10);
ALTER TABLE WLT_TRAN_DEF  ALTER COLUMN FEE_TRAN_TYPE      TYPE VARCHAR(10);
ALTER TABLE WLT_TRAN_HIST ALTER COLUMN TRAN_TYPE          TYPE VARCHAR(10);  -- cascades to partitions

-- -----------------------------------------------------------------------------
-- PART B — Vietnamese e-wallet transaction catalogue
-- -----------------------------------------------------------------------------
-- Columns:
--  TRAN_TYPE, TRAN_DESC, CR_DR_MAINT_IND, REVERSAL_TRAN_TYPE,
--  CHECK_FUND_IND, CHECK_RESTRAINT_IND, SOURCE_TYPE, CONTRA_GL_CODE,
--  MIN_TRAN_AMT, MAX_TRAN_AMT, AUTO_APPROVAL, NARRATIVE, STATUS,
--  FEE_TYPE, FEE_AMT, FEE_RATE, FEE_MIN, FEE_MAX, VAT_RATE,
--  FEE_GL_CODE, VAT_GL_CODE, FEE_TRAN_TYPE

INSERT INTO WLT_TRAN_DEF
 (TRAN_TYPE, TRAN_DESC, CR_DR_MAINT_IND, REVERSAL_TRAN_TYPE,
  CHECK_FUND_IND, CHECK_RESTRAINT_IND, SOURCE_TYPE, CONTRA_GL_CODE,
  MIN_TRAN_AMT, MAX_TRAN_AMT, AUTO_APPROVAL, NARRATIVE, STATUS,
  FEE_TYPE, FEE_AMT, FEE_RATE, FEE_MIN, FEE_MAX, VAT_RATE,
  FEE_GL_CODE, VAT_GL_CODE, FEE_TRAN_TYPE)
VALUES
 -- ── Nạp tiền qua đại lý / điểm giao dịch (agent cash-in) ────────────────────
 ('DEPOSIT',  'Nạp ví qua đại lý',          'CR','RVDEP',  'N','N','AGENT', NULL,
   10000, 500000000, 'Y','Deposit','A',  'FIXED', 5500, 0, 0, 0, 0.10, '401.01','203.01','FEEDEP'),
 ('FEEDEP',   'Phí nạp qua đại lý',          'DR','RVFEE',  'N','N','SYS',   '401.01',
   0, 10000000, 'Y','Fee','A',           'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),

 -- ── Thanh toán QR / merchant (ví → clearing; MDR thu tại bước SETTLE) ───────
 ('PAYMENT',  'Thanh toán QR/merchant',      'DR','RVPAY',  'Y','Y','MOBILE','109.03.001',
   1000, 100000000, 'Y','Payment','A',   'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),

 -- ── Thanh toán hóa đơn (điện, nước, internet, truyền hình) ─────────────────
 ('BILLPAY',  'Thanh toán hóa đơn',          'DR','RVBILL', 'Y','Y','MOBILE','109.03.001',
   1000, 100000000, 'Y','Bill payment','A','NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),

 -- ── Nạp tiền điện thoại / data (airtime/topup telco) ───────────────────────
 ('AIRTIME',  'Nạp ĐT / data',               'DR','RVAIR',  'Y','Y','MOBILE','109.03.001',
   10000, 5000000, 'Y','Airtime','A',    'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),

 -- ── Quyết toán merchant (clearing → ví merchant, trừ MDR) ──────────────────
 ('SETTLE',   'Quyết toán merchant',         'CR','RVSETTL','N','N','SYS',   '109.03.001',
   0, 5000000000, 'Y','Settlement','A',  'PERCENT', 0, 0.011, 0, 100000000, 0.10, '401.03','203.01','MDRFEE'),
 ('MDRFEE',   'Phí chiết khấu MDR',          'DR','RVFEE',  'N','N','SYS',   '401.03',
   0, 100000000, 'Y','MDR','A',          'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),

 -- ── Hoàn tiền khuyến mãi / cashback (chi phí KM → ví khuyến mãi) ────────────
 ('CASHBACK', 'Hoàn tiền khuyến mãi',        'CR','RVCASH', 'N','N','SYS',   '502.01',
   1000, 50000000, 'Y','Cashback','A',   'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),

 -- ── Hoàn tiền giao dịch (merchant/biller refund về ví khách) ───────────────
 ('REFUND',   'Hoàn tiền giao dịch',         'CR','RVREF',  'N','N','SYS',   '109.03.001',
   1000, 100000000, 'Y','Refund','A',    'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),

 -- ── Điều chỉnh thủ công (ops) — bắt buộc duyệt tay (AUTO_APPROVAL='N') ──────
 ('ADJCR',    'Điều chỉnh tăng (ops)',       'CR','RVADJ',  'N','N','OPS',   '109.04.001',
   0, 1000000000, 'N','Adjust CR','A',   'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),
 ('ADJDR',    'Điều chỉnh giảm (ops)',       'DR','RVADJ',  'Y','N','OPS',   '109.04.001',
   0, 1000000000, 'N','Adjust DR','A',   'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),

 -- ── Reversals cho các loại mới ─────────────────────────────────────────────
 ('RVDEP',    'Đảo nạp đại lý',              'DR', NULL,    'N','N','SYS',   NULL,
   0, 500000000, 'Y','Reversal','A',     'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),
 ('RVPAY',    'Đảo thanh toán',              'CR', NULL,    'N','N','SYS',   '109.03.001',
   0, 100000000, 'Y','Reversal','A',     'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),
 ('RVBILL',   'Đảo TT hóa đơn',              'CR', NULL,    'N','N','SYS',   '109.03.001',
   0, 100000000, 'Y','Reversal','A',     'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),
 ('RVAIR',    'Đảo nạp ĐT',                  'CR', NULL,    'N','N','SYS',   '109.03.001',
   0, 5000000, 'Y','Reversal','A',       'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),
 ('RVSETTL',  'Đảo quyết toán',              'DR', NULL,    'N','N','SYS',   '109.03.001',
   0, 5000000000, 'Y','Reversal','A',    'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),
 ('RVCASH',   'Đảo cashback',                'DR', NULL,    'N','N','SYS',   '502.01',
   0, 50000000, 'Y','Reversal','A',      'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),
 ('RVREF',    'Đảo hoàn tiền',               'DR', NULL,    'N','N','SYS',   '109.03.001',
   0, 100000000, 'Y','Reversal','A',     'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),
 ('RVADJ',    'Đảo điều chỉnh',              'BOTH',NULL,   'N','N','SYS',   '109.04.001',
   0, 1000000000, 'N','Reversal','A',    'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL),
 -- Fee-free internal transfer — same as TRFOUT but FEE_TYPE NONE. Lets the
 -- transaction API toggle "có phí / không phí" purely by tran_type (post_transfer).
 ('TRFOUTF',  'Chuyển tiền nội bộ (miễn phí)','DR','RVTRF',  'Y','Y','MOBILE', NULL,
   1000, 100000000, 'Y','Transfer free','A', 'NONE', 0,0,0,0, 0.00, NULL,NULL,NULL)
ON CONFLICT (TRAN_TYPE) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Wallet event → GL mapping for the new payment/settlement flows
-- -----------------------------------------------------------------------------
INSERT INTO WLT_GL_MAP (ACCT_TYPE, EVENT_TYPE, GL_CODE, GL_DESC) VALUES
  ('CONSUMER', 'BILLER_CLR',  '109.03.001', 'Payment clearing — bill/airtime'),
  ('CONSUMER', 'COMM_CR',     '401.04',     'Bill/topup commission income'),
  ('CONSUMER', 'REFUND_CR',   '201.01.001', 'Refund to consumer wallet'),
  ('CONSUMER', 'ADJ_SUSP',    '109.04.001', 'Manual adjustment suspense'),
  ('MERCHANT', 'MDR_CR',      '401.03',     'Merchant discount rate'),
  ('MERCHANT', 'SETTLE_CLR',  '109.03.001', 'Payment clearing — settlement source')
ON CONFLICT (ACCT_TYPE, EVENT_TYPE) DO NOTHING;

COMMIT;
