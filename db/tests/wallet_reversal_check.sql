-- =============================================================================
-- wallet_reversal_check.sql — Kiểm tra giao dịch ĐÃ ĐƯỢC REVERSAL
-- =============================================================================
-- PURE SQL, read-only. Chạy: psql / DBeaver (Execute SQL Script).
--   docker exec -i wallet-postgres psql -U postgres -d wallet < db/tests/wallet_reversal_check.sql
--
-- Liên kết reversal -> giao dịch gốc (chuẩn kép vì SP lưu khác nhau theo loại):
--   • RVTRF / RVTPUP  : orig_seq_no = SEQ_NO của bút toán gốc
--   • RVWD            : orig_seq_no = TFR_INTERNAL_KEY của lệnh rút gốc (từ withdraw_track)
--   → keymap ánh xạ cả seq_no LẪN tfr_internal_key của giao dịch gốc về tfr_internal_key.
--
-- Phạm vi = tháng hiện tại (đổi date_trunc('month',CURRENT_DATE) nếu cần).
--
-- Output 1: bảng PASS/FAIL các invariant của reversal (R1..R5).
-- Output 2: danh sách giao dịch gốc đã bị reversal (50 dòng mới nhất).
-- =============================================================================
SET statement_timeout = 0;

WITH
mn AS (SELECT date_trunc('month', CURRENT_DATE)::date AS d),
-- 1 dòng / giao dịch reversal
rev AS (
  SELECT r.tfr_internal_key                                   AS rev_key,
         min(r.orig_seq_no)                                   AS orig_link,
         string_agg(DISTINCT r.tran_type,'+' ORDER BY r.tran_type) AS rev_types,
         max(r.time_stamp)                                    AS rev_time,
         min(r.reference)                                     AS rev_ref,
         -- transfer reversal có 2 chân RVTRF cùng giá trị → dùng max (số tiền đầu mục), không cộng dồn
         max(r.tran_amt) FILTER (WHERE r.tran_type IN ('RVTRF','RVWD','RVTPUP')) AS rev_principal
  FROM wlt_tran_hist r, mn
  WHERE r.tran_type LIKE 'RV%' AND r.post_date >= mn.d
  GROUP BY r.tfr_internal_key
),
-- 1 dòng / giao dịch gốc (không phải RV)
orig AS (
  SELECT o.tfr_internal_key,
         min(o.reference)                                     AS ref,
         string_agg(DISTINCT o.tran_type,'+' ORDER BY o.tran_type) AS types,
         max(o.tran_amt) FILTER (WHERE o.tran_type IN ('TRFOUT','TRFOUTF','WDRAW','TOPUP')) AS principal
  FROM wlt_tran_hist o, mn
  WHERE o.tran_type NOT LIKE 'RV%' AND o.post_date >= mn.d AND o.tfr_internal_key IS NOT NULL
  GROUP BY o.tfr_internal_key
),
-- ánh xạ mọi khóa có thể (seq_no & tfr_internal_key) -> giao dịch gốc
keymap AS (
  SELECT o.seq_no AS link, o.tfr_internal_key AS orig_txn
  FROM wlt_tran_hist o, mn WHERE o.tran_type NOT LIKE 'RV%' AND o.post_date >= mn.d
  UNION
  SELECT o.tfr_internal_key AS link, o.tfr_internal_key AS orig_txn
  FROM wlt_tran_hist o, mn WHERE o.tran_type NOT LIKE 'RV%' AND o.post_date >= mn.d
),
-- mỗi reversal -> giao dịch gốc
resolved AS (
  SELECT rev.*, km.orig_txn, o.ref AS orig_ref, o.types AS orig_types, o.principal AS orig_principal
  FROM rev
  LEFT JOIN keymap km ON km.link = rev.orig_link
  LEFT JOIN orig   o  ON o.tfr_internal_key = km.orig_txn
),
checks(ord, area, name, ok, detail) AS (
  SELECT 0,'—','CONTEXT', TRUE,
         format('period từ %s | reversals=%s | giao dịch gốc đã reversal=%s',
                (SELECT d FROM mn),
                (SELECT count(*) FROM rev),
                (SELECT count(DISTINCT orig_txn) FROM resolved WHERE orig_txn IS NOT NULL))
  -- R1: mọi reversal phải liên kết được tới 1 giao dịch gốc
  UNION ALL
  SELECT 1,'R1','Reversal có gốc (không orphan)',
         count(*) FILTER(WHERE orig_txn IS NULL)=0,
         format('%s/%s reversal orphan (không tìm thấy gốc)',
                count(*) FILTER(WHERE orig_txn IS NULL), count(*))
  FROM resolved
  -- R2: không double-reversal (1 gốc bị reversal >1 lần)
  UNION ALL
  SELECT 2,'R2','Không double-reversal', count(*) FILTER(WHERE c>1)=0,
         format('%s giao dịch gốc bị reversal nhiều lần', count(*) FILTER(WHERE c>1))
  FROM (SELECT orig_txn, count(DISTINCT rev_key) c FROM resolved WHERE orig_txn IS NOT NULL GROUP BY orig_txn) x
  -- R3: số tiền gốc của reversal = số tiền gốc của giao dịch gốc
  UNION ALL
  SELECT 3,'R3','Số tiền reversal = số tiền gốc',
         count(*) FILTER(WHERE orig_txn IS NOT NULL AND rev_principal IS DISTINCT FROM orig_principal)=0,
         format('%s reversal lệch số tiền so với gốc',
                count(*) FILTER(WHERE orig_txn IS NOT NULL AND rev_principal IS DISTINCT FROM orig_principal))
  FROM resolved
  -- R4: mỗi giao dịch reversal tự cân (ΣDR=ΣCR ở GL)
  UNION ALL
  SELECT 4,'R4','Mỗi reversal cân (ΣDR=ΣCR)', count(*)=0,
         format('%s reversal lệch double-entry', count(*))
  FROM (SELECT b.tran_key FROM wlt_gl_batch b
        WHERE b.tran_key IN (SELECT rev_key FROM rev)
        GROUP BY b.tran_key
        HAVING sum(CASE b.tran_nature WHEN 'DR' THEN b.amount ELSE -b.amount END)<>0) y
  -- R5: giao dịch gốc đã reversal không bị reversal lại bằng orig_seq_no rỗng
  UNION ALL
  SELECT 5,'R5','Mọi reversal có orig_seq_no', count(*) FILTER(WHERE orig_link IS NULL)=0,
         format('%s reversal thiếu orig_seq_no', count(*) FILTER(WHERE orig_link IS NULL))
  FROM resolved
)
SELECT ord, area, name,
       CASE WHEN ord=0 THEN 'ℹ︎' WHEN ok THEN '✅ PASS' ELSE '❌ FAIL' END AS result,
       detail
FROM checks
UNION ALL
SELECT 99,'==','OVERALL VERDICT',
       CASE WHEN bool_and(ok) FILTER(WHERE ord>0) THEN '✅ ALL PASS' ELSE '❌ FAIL' END,
       format('%s/%s pass', count(*) FILTER(WHERE ok AND ord>0), count(*) FILTER(WHERE ord>0))
FROM checks
ORDER BY ord;
