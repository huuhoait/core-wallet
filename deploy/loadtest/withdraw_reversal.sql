-- pgbench: WITHDRAW REVERSAL — reversal WITH fee refund. Post a withdraw (WDRAW,
-- fee+VAT) then immediately reverse it. Exercises the heavy fee-refund path:
-- RVWD (principal back) + RVFEE (fee back to wallet) + DR reversal of revenue
-- 401.01 / VAT 203.01, plus the WLT_WITHDRAW_TRACK treasury-status transition.
-- Self-contained so the reversal always finds a fresh POSTED payout to claw back.
-- Counts as 1 pgbench transaction = 2 SP calls (withdraw + withdraw_reversal).
\set a random(1, :nwallet)
\set amt random(50000, 500000)
\set r random(1, 2000000000)
SELECT post_withdraw('LT'||lpad((:a)::text,10,'0'), :amt,
                     'PB-RVW-' || :client_id || '-' || :r,
                     'PBEXT-RVW-' || :client_id || '-' || :r,
                     'BIDV', '9990000000', '{}'::jsonb, 'MOBILE', 'pgbench');
SELECT post_withdraw_reversal('PBEXT-RVW-' || :client_id || '-' || :r,
                              'NAPAS_TIMEOUT', 'load-test reversal', 'TREASURY_FAILED', 'SYS', 'pgbench');
