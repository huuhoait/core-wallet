-- =============================================================================
-- wallet_reconciliation_check.sql — Read-only accounting & reconciliation audit
-- =============================================================================
-- PURE SQL (không dùng lệnh psql \set/\gset) → chạy được trên psql, DBeaver,
-- pgAdmin, bất kỳ JDBC client nào. Chỉ SELECT, không sửa dữ liệu.
--
-- Phạm vi sổ cái = THÁNG HIỆN TẠI (prune partition wlt_tran_hist để tránh lock).
-- Muốn audit nhiều/khác tháng: thay  date_trunc('month', CURRENT_DATE)::date
-- bằng literal, vd  DATE '2026-01-01'  (3 chỗ: check D, E, F, G).
--
-- Invariant: A trial balance · B double-entry/giao dịch · C bản chất Nợ-Có GL
--   D actual_bal=Σsổ cái · E running-balance math · F chain continuity
--   G half-applied · H ánh xạ GL ví · I VAT=10% · J solvency · K số dư âm
--
-- LƯU Ý: chạy CẢ FILE (gồm cả dòng SET) — role mặc định có statement_timeout
-- ngắn; SET tắt timeout cho phiên audit. (DBeaver: Execute SQL Script / Alt+X.)
-- =============================================================================
SET statement_timeout = 0;

WITH
-- sổ cái tổng hợp 1 lần/ví (dùng cho D + G): Σ(CR-DR) và bút toán mới nhất
ledger AS (
  SELECT internal_key,
         sum(CASE cr_dr_maint_ind WHEN 'CR' THEN tran_amt ELSE -tran_amt END) AS sum_signed,
         (array_agg(actual_bal_amt ORDER BY post_date DESC, seq_no DESC))[1]  AS last_act
  FROM wlt_tran_hist
  WHERE post_date >= date_trunc('month', CURRENT_DATE)::date
  GROUP BY internal_key
),
-- quét sổ cái 1 lần cho E + F (per-row math + chain)
seqd AS (
  SELECT (actual_bal_amt <> previous_bal_amt
            + (CASE cr_dr_maint_ind WHEN 'CR' THEN tran_amt ELSE -tran_amt END)) AS bad_math,
         (lag(actual_bal_amt) OVER (PARTITION BY internal_key ORDER BY seq_no) IS NOT NULL
            AND previous_bal_amt <> lag(actual_bal_amt) OVER (PARTITION BY internal_key ORDER BY seq_no)) AS bad_chain
  FROM wlt_tran_hist
  WHERE post_date >= date_trunc('month', CURRENT_DATE)::date
),
-- gắn mỗi giao dịch (tran_key) với tập tran_type của nó (cho L + M)
flow AS (
  SELECT tfr_internal_key AS tk,
         string_agg(DISTINCT tran_type,'+' ORDER BY tran_type) AS types
  FROM wlt_tran_hist
  WHERE tfr_internal_key IS NOT NULL
    AND post_date >= date_trunc('month', CURRENT_DATE)::date
  GROUP BY tfr_internal_key
),
a AS (
  SELECT (coalesce(sum(CASE tran_nature WHEN 'DR' THEN amount ELSE -amount END),0)=0) ok,
         format('DR=%s CR=%s diff=%s',
           coalesce(sum(amount) FILTER(WHERE tran_nature='DR'),0),
           coalesce(sum(amount) FILTER(WHERE tran_nature='CR'),0),
           coalesce(sum(CASE tran_nature WHEN 'DR' THEN amount ELSE -amount END),0)) detail
  FROM wlt_batch
),
b AS (
  SELECT count(*)=0 ok, format('%s tran_key lệch', count(*)) detail
  FROM (SELECT tran_key FROM wlt_batch GROUP BY tran_key
        HAVING sum(CASE tran_nature WHEN 'DR' THEN amount ELSE -amount END)<>0) x
),
c AS (
  SELECT count(*) FILTER(WHERE NOT side_ok)=0 ok,
         format('%s/%s GL sai phía: %s', count(*) FILTER(WHERE NOT side_ok), count(*),
                coalesce(string_agg(gl_code,',') FILTER(WHERE NOT side_ok),'-')) detail
  FROM (
    SELECT b.gl_code,
           CASE WHEN m.gl_code_type IN ('A','E')
                THEN sum(CASE b.tran_nature WHEN 'DR' THEN b.amount ELSE -b.amount END)>=0
                ELSE sum(CASE b.tran_nature WHEN 'DR' THEN b.amount ELSE -b.amount END)<=0 END side_ok
    FROM wlt_batch b JOIN fm_gl_mast m USING(gl_code)
    WHERE m.gl_code_type IS NOT NULL
    GROUP BY b.gl_code, m.gl_code_type) s
),
d AS (
  SELECT count(*) FILTER(WHERE diff<>0)=0 ok,
         format('%s/%s ví lệch (Σ|diff|=%s)', count(*) FILTER(WHERE diff<>0), count(*),
                coalesce(sum(abs(diff)),0)) detail
  FROM (SELECT a.actual_bal - COALESCE(l.sum_signed,0) diff
        FROM wlt_acct a LEFT JOIN ledger l USING(internal_key)) z
),
e AS (
  SELECT count(*) FILTER(WHERE bad_math)=0 ok,
         format('%s dòng sai', count(*) FILTER(WHERE bad_math)) detail FROM seqd
),
f AS (
  SELECT count(*) FILTER(WHERE bad_chain)=0 ok,
         format('%s mắt xích đứt', count(*) FILTER(WHERE bad_chain)) detail FROM seqd
),
g AS (
  SELECT count(*) FILTER(WHERE a.actual_bal <> l.last_act)=0 ok,
         format('%s ví: actual_bal ≠ bút toán cuối', count(*) FILTER(WHERE a.actual_bal <> l.last_act)) detail
  FROM wlt_acct a JOIN ledger l USING(internal_key)
),
h AS (
  SELECT count(*)=0 ok, format('%s leg sai GL ví', count(*)) detail
  FROM wlt_batch b JOIN wlt_acct a ON a.internal_key=b.acct_internal_key
  WHERE b.gl_code IN ('201.01.001','201.02.001')
    AND ((a.acct_type='CONSUMER' AND b.gl_code<>'201.01.001')
      OR (a.acct_type='MERCHANT' AND b.gl_code<>'201.02.001'))
),
i AS (
  SELECT abs(vat - net*0.10) <= 0.01*greatest(nfee,1) ok,
         format('VAT=%s net=%s tỉ lệ=%s (n=%s)', vat, net,
                CASE WHEN net=0 THEN NULL ELSE round(vat/net,4) END, nfee) detail
  FROM (
    SELECT coalesce((SELECT sum(amount) FROM wlt_batch WHERE gl_code='203.01' AND tran_nature='CR'),0) vat,
           coalesce((SELECT sum(amount) FROM wlt_batch WHERE gl_code IN ('401.01','401.02') AND tran_nature='CR'),0) net,
           (SELECT count(*) FROM wlt_batch WHERE gl_code='203.01' AND tran_nature='CR') nfee) v
),
j AS (
  SELECT asset_dr >= cust_liab ok,
         format('asset(101)=%s cust_liab(201+204)=%s đệm(phí+VAT)=%s',
                asset_dr, cust_liab, asset_dr-cust_liab) detail
  FROM (
    SELECT coalesce((SELECT sum(CASE tran_nature WHEN 'DR' THEN amount ELSE -amount END)
                     FROM wlt_batch WHERE gl_code LIKE '101%'),0) asset_dr,
           coalesce((SELECT -sum(CASE tran_nature WHEN 'DR' THEN amount ELSE -amount END)
                     FROM wlt_batch WHERE gl_code LIKE '201%' OR gl_code LIKE '204%'),0) cust_liab) s
),
k AS (
  SELECT count(*)=0 ok, format('%s ví vi phạm', count(*)) detail
  FROM wlt_acct WHERE actual_bal < 0 OR actual_bal < total_restrained_amt
),
-- L. Mỗi luồng (topup/transfer/withdraw/merchant-WD/reversal...) ΣDR=ΣCR
l AS (
  SELECT count(*) FILTER(WHERE dr<>cr)=0 ok,
         format('%s/%s luồng lệch', count(*) FILTER(WHERE dr<>cr), count(*)) detail
  FROM (
    SELECT f.types,
           coalesce(sum(b.amount) FILTER(WHERE b.tran_nature='DR'),0) dr,
           coalesce(sum(b.amount) FILTER(WHERE b.tran_nature='CR'),0) cr
    FROM wlt_batch b JOIN flow f ON f.tk=b.tran_key
    GROUP BY f.types) g
),
-- M. Phân loại GL phí: merchant-WD→401.02, transfer/consumer-WD→401.01
m AS (
  SELECT (wrong_mw + wrong_other)=0 ok,
         format('merchant-WD sai 401.01=%s · non-merchant sai 401.02=%s', wrong_mw, wrong_other) detail
  FROM (
    SELECT count(*) FILTER(WHERE f.types LIKE '%MERCHWD%' AND b.gl_code='401.01') wrong_mw,
           count(*) FILTER(WHERE f.types NOT LIKE '%MERCHWD%' AND b.gl_code='401.02') wrong_other
    FROM wlt_batch b JOIN flow f ON f.tk=b.tran_key
    WHERE b.gl_code IN ('401.01','401.02')) z
),
checks(ord, area, name, ok, detail) AS (
  SELECT  0,'—','CONTEXT', TRUE,
          format('period từ %s | ví=%s | batch_legs=%s',
                 date_trunc('month', CURRENT_DATE)::date,
                 (SELECT count(*) FROM wlt_acct), (SELECT count(*) FROM wlt_batch))
  UNION ALL SELECT  1,'A','Trial balance ΣDR=ΣCR',            ok,detail FROM a
  UNION ALL SELECT  2,'B','Double-entry mỗi giao dịch',        ok,detail FROM b
  UNION ALL SELECT  3,'C','Bản chất Nợ/Có của GL',            ok,detail FROM c
  UNION ALL SELECT  4,'D','actual_bal = Σ sổ cái',             ok,detail FROM d
  UNION ALL SELECT  5,'E','Running-balance math',              ok,detail FROM e
  UNION ALL SELECT  6,'F','Chain continuity',                  ok,detail FROM f
  UNION ALL SELECT  7,'G','Không giao dịch half-applied',      ok,detail FROM g
  UNION ALL SELECT  8,'H','Ánh xạ GL ví theo acct_type',       ok,detail FROM h
  UNION ALL SELECT  9,'I','VAT = 10% net revenue',             ok,detail FROM i
  UNION ALL SELECT 10,'J','Solvency: TS ≥ NPT khách',          ok,detail FROM j
  UNION ALL SELECT 11,'K','Số dư không âm / không vượt PT',    ok,detail FROM k
  UNION ALL SELECT 12,'L','Mỗi luồng cân (topup/WD/merchant)', ok,detail FROM l
  UNION ALL SELECT 13,'M','Phân loại GL phí (merchant 401.02)',ok,detail FROM m
)
SELECT ord, area, name,
       CASE WHEN ord=0 THEN 'ℹ︎' WHEN ok THEN '✅ PASS' ELSE '❌ FAIL' END AS result,
       detail
FROM checks
UNION ALL
SELECT 99, '==', 'OVERALL VERDICT',
       CASE WHEN bool_and(ok) FILTER(WHERE ord>0) THEN '✅ ALL PASS' ELSE '❌ FAIL' END,
       format('%s/%s pass', count(*) FILTER(WHERE ok AND ord>0), count(*) FILTER(WHERE ord>0))
FROM checks
ORDER BY ord;
