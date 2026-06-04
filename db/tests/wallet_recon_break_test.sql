-- =============================================================================
-- wallet_recon_break_test.sql — Kiểm tra SP ghi nhận reconciliation break
-- =============================================================================
-- Đối tượng: fn_record_recon_breaks(p_biz_date) + bảng wlt_recon_break.
-- SP chạy lại các invariant kế toán A..M (giống audit read-only
-- db/tests/wallet_reconciliation_check.sql) và GHI một dòng vào wlt_recon_break
-- cho mỗi invariant FAIL, gắn chung một run_id.
--
-- Chạy: psql / DBeaver (Execute SQL Script).
--   docker compose exec -T postgres psql -U postgres -d wallet < db/tests/wallet_recon_break_test.sql
--
-- TOÀN BỘ test nằm trong 1 transaction và ROLLBACK ở cuối → KHÔNG để lại dữ liệu
-- (không dòng recon_break, không sửa số dư). An toàn chạy trên DB seed bất kỳ.
--
-- T1: chạy trên dữ liệu hiện tại → số dòng đã ghi = breaks_recorded trả về.
-- T2: cố tình lệch actual_bal 1 ví → SP phải bắt được break số dư (D/G),
--     status mặc định 'OPEN', cột audit (created_by) được điền. Bỏ qua nếu DB
--     chưa có ví (init trống) — nạp db/seeds/wallet_testdata_10.sql để chạy đủ.
-- =============================================================================
SET statement_timeout = 0;

BEGIN;

-- T1 — tính toàn vẹn: SP báo bao nhiêu break thì ghi đúng bấy nhiêu dòng -------
DO $$
DECLARE r record; n bigint;
BEGIN
  SELECT * INTO r FROM fn_record_recon_breaks(CURRENT_DATE);
  SELECT count(*) INTO n FROM wlt_recon_break WHERE run_id = r.run_id;
  IF n <> r.breaks_recorded THEN
    RAISE EXCEPTION 'T1 FAIL: ghi % dòng nhưng báo breaks_recorded=%', n, r.breaks_recorded;
  END IF;
  RAISE NOTICE 'T1 OK: ghi % break, run_id=%', r.breaks_recorded, r.run_id;
END $$;

-- T2 — phát hiện: gây lệch số dư rồi xác nhận SP bắt được --------------------
DO $$
DECLARE r record; n_bal bigint; v_status text; v_by text;
BEGIN
  IF (SELECT count(*) FROM wlt_acct) = 0 THEN
    RAISE NOTICE 'T2 SKIP: DB chưa có ví (nạp db/seeds/wallet_testdata_10.sql để test phát hiện)';
  ELSE
    UPDATE wlt_acct SET actual_bal = actual_bal + 12345
    WHERE internal_key = (SELECT internal_key FROM wlt_acct ORDER BY internal_key LIMIT 1);

    SELECT * INTO r FROM fn_record_recon_breaks(CURRENT_DATE);
    SELECT count(*) INTO n_bal FROM wlt_recon_break WHERE run_id = r.run_id AND area IN ('D','G');
    IF n_bal = 0 THEN
      RAISE EXCEPTION 'T2 FAIL: lệch actual_bal nhưng SP không ghi break số dư (D/G)';
    END IF;

    SELECT status, created_by INTO v_status, v_by
    FROM wlt_recon_break WHERE run_id = r.run_id LIMIT 1;
    IF v_status <> 'OPEN' OR v_by IS NULL THEN
      RAISE EXCEPTION 'T2 FAIL: default/audit chưa được điền (status=%, by=%)', v_status, v_by;
    END IF;
    RAISE NOTICE 'T2 OK: lệch số dư sinh % break (D/G), status=%, by=%', n_bal, v_status, v_by;
  END IF;
END $$;

ROLLBACK;

SELECT 'wallet_recon_break_test: PASS (xem NOTICE ở trên; mọi thay đổi đã ROLLBACK)' AS result;
