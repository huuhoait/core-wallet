-- =============================================================================
-- wallet_opening_balance_backfill.sql
-- Cân lại các bút toán lệch: backfill bút toán SỐ DƯ ĐẦU KỲ (TOPUP) cho các ví
-- có actual_bal được nạp off-ledger (không có bút toán trong wlt_tran_hist).
--
-- Mỗi ví lệch nhận:
--   • 1 dòng wlt_tran_hist: TOPUP / CR / prev=0 / act=opening / seq_no=0 (xếp đầu chuỗi)
--   • 2 leg wlt_gl_batch:  DR 101.02.001 (Nostro @ Bank)  /  CR ví (201.01.001 | 201.02.001)
-- KHÔNG sửa wlt_acct.actual_bal (đã đúng).
--
-- opening = actual_bal - Σ(CR-DR ledger)  (= previous_bal_amt của bút toán đầu tiên)
-- Idempotent: chỉ xử lý ví đang lệch (actual_bal <> Σledger).
-- Tự kiểm tra cuối transaction; RAISE EXCEPTION -> ROLLBACK nếu invariant sai.
-- =============================================================================
BEGIN;

DO $$
DECLARE
  r RECORD;
  v_key       BIGINT;
  v_ledger    NUMERIC(18,2);
  v_opening   NUMERIC(18,2);
  v_postdate  DATE;
  v_wallet_gl VARCHAR(32);
  v_n         INT := 0;
  v_total     NUMERIC(18,2) := 0;
BEGIN
  FOR r IN
    SELECT a.internal_key, a.acct_no, a.client_no, a.acct_type, a.ccy, a.actual_bal
    FROM wlt_acct a
    WHERE a.acct_no NOT LIKE 'LT%'        -- loại trừ ví ephemeral của pgbench load-test
    ORDER BY a.internal_key
  LOOP
    -- Σ(CR-DR) đã ghi sổ cho ví này (dùng leaf partition để tránh lock)
    SELECT COALESCE(sum(CASE cr_dr_maint_ind WHEN 'CR' THEN tran_amt ELSE -tran_amt END),0),
           min(post_date)
      INTO v_ledger, v_postdate
      FROM wlt_tran_hist_2026_05
     WHERE internal_key = r.internal_key;

    v_opening := r.actual_bal - v_ledger;

    -- chỉ xử lý ví đang lệch
    CONTINUE WHEN v_opening = 0;
    -- an toàn: không backfill số âm
    IF v_opening < 0 THEN
      RAISE EXCEPTION 'Acct % opening âm (%): cần điều tra thủ công', r.acct_no, v_opening;
    END IF;
    IF v_postdate IS NULL THEN v_postdate := CURRENT_DATE; END IF;

    v_wallet_gl := CASE r.acct_type WHEN 'MERCHANT' THEN '201.02.001' ELSE '201.01.001' END;
    v_key := nextval('seq_tfr');

    -- (1) Bút toán số dư đầu kỳ trong sổ cái khách hàng — xếp đầu chuỗi (seq_no=0)
    INSERT INTO wlt_tran_hist
      (internal_key, seq_no, tran_type, post_date, value_date,
       tran_amt, cr_dr_maint_ind, previous_bal_amt, actual_bal_amt,
       tfr_internal_key, reference, ccy, source_module, tran_desc, created_by, updated_by)
    OVERRIDING SYSTEM VALUE
    VALUES
      (r.internal_key, 0, 'TOPUP', v_postdate, v_postdate,
       v_opening, 'CR', 0, v_opening,
       v_key, 'OPENING-BAL-'||r.acct_no, r.ccy, 'WLT', 'Opening balance brought forward', 'RECON', 'RECON');

    -- (2) Hai leg GL double-entry (giống post_topup): DR Nostro / CR ví
    INSERT INTO wlt_gl_batch
      (tran_key, seq_no, gl_code, client_no, acct_internal_key, amount, tran_nature,
       ccy, reference, narrative, post_date, value_date, source_module, status, created_by, updated_by)
    VALUES
      (v_key, 1, '101.02.001', r.client_no, r.internal_key, v_opening, 'DR',
       r.ccy, 'OPENING-BAL-'||r.acct_no, 'Opening balance — nostro funding', v_postdate, v_postdate, 'WLT', 'P', 'RECON', 'RECON'),
      (v_key, 2, v_wallet_gl,  r.client_no, r.internal_key, v_opening, 'CR',
       r.ccy, 'OPENING-BAL-'||r.acct_no, 'Opening balance brought forward', v_postdate, v_postdate, 'WLT', 'P', 'RECON', 'RECON');

    v_n := v_n + 1;
    v_total := v_total + v_opening;
    RAISE NOTICE 'Backfill % (%): opening=% -> GL % CR, Nostro DR', r.acct_no, r.acct_type, v_opening, v_wallet_gl;
  END LOOP;

  RAISE NOTICE '=== Đã backfill % ví, tổng số dư đầu kỳ = % ===', v_n, v_total;
END $$;

-- ── KIỂM TRA SAU KHI CÂN (raise -> rollback nếu sai) ───────────────────────
DO $$
DECLARE
  v_bad_recon INT;
  v_dr NUMERIC; v_cr NUMERIC;
  v_bad_chain INT;
  v_bad_math  INT;
BEGIN
  -- (a) actual_bal phải = Σledger cho MỌI ví
  SELECT count(*) INTO v_bad_recon FROM (
    SELECT a.internal_key
    FROM wlt_acct a
    LEFT JOIN (SELECT internal_key,
                      sum(CASE cr_dr_maint_ind WHEN 'CR' THEN tran_amt ELSE -tran_amt END) s
               FROM wlt_tran_hist_2026_05 GROUP BY internal_key) l USING (internal_key)
    WHERE a.acct_no NOT LIKE 'LT%'        -- bỏ qua ví load-test (off-ledger có chủ đích, ephemeral)
      AND a.actual_bal <> COALESCE(l.s,0)
  ) x;

  -- (b) trial balance toàn cục
  SELECT sum(amount) FILTER (WHERE tran_nature='DR'),
         sum(amount) FILTER (WHERE tran_nature='CR')
    INTO v_dr, v_cr FROM wlt_gl_batch;

  -- (c) running-balance math + (d) chain continuity
  SELECT count(*) INTO v_bad_math FROM wlt_tran_hist_2026_05
   WHERE actual_bal_amt <> previous_bal_amt + (CASE cr_dr_maint_ind WHEN 'CR' THEN tran_amt ELSE -tran_amt END);

  SELECT count(*) INTO v_bad_chain FROM (
    SELECT previous_bal_amt,
           lag(actual_bal_amt) OVER (PARTITION BY internal_key ORDER BY seq_no) prev_act
    FROM wlt_tran_hist_2026_05) c
   WHERE prev_act IS NOT NULL AND previous_bal_amt <> prev_act;

  RAISE NOTICE 'recon_mismatch=%  trial_DR=%  trial_CR=%  bad_math=%  bad_chain=%',
    v_bad_recon, v_dr, v_cr, v_bad_math, v_bad_chain;

  IF v_bad_recon <> 0 THEN RAISE EXCEPTION 'FAIL: còn % ví lệch actual_bal vs sổ cái', v_bad_recon; END IF;
  IF v_dr <> v_cr     THEN RAISE EXCEPTION 'FAIL: trial balance lệch DR=% CR=%', v_dr, v_cr; END IF;
  IF v_bad_math <> 0  THEN RAISE EXCEPTION 'FAIL: % dòng sai running-balance math', v_bad_math; END IF;
  IF v_bad_chain <> 0 THEN RAISE EXCEPTION 'FAIL: % mắt xích chuỗi đứt', v_bad_chain; END IF;

  RAISE NOTICE '=== OK: mọi invariant đạt, commit ===';
END $$;

COMMIT;
