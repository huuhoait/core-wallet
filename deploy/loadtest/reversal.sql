-- pgbench: REVERSAL workload — post a transfer then immediately reverse it.
-- Self-contained so the reversal always finds a POSTED original and the
-- claw-back from B succeeds (B was just credited in the same pgbench txn).
-- Counts as 1 pgbench transaction = 2 SP calls (transfer + transfer_reversal).
\set a random(1, :nwallet)
\set b ((:a % :nwallet) + 1)
\set amt random(1000, 100000)
\set r random(1, 2000000000)
SELECT post_transfer('LT'||lpad((:a)::text,10,'0'), 'LT'||lpad((:b)::text,10,'0'), :amt,
                     'PB-RVT-' || :client_id || '-' || :r, 'TRFOUT', '{}'::jsonb, 'MOBILE', 'pgbench');
SELECT post_transfer_reversal('PB-RVT-' || :client_id || '-' || :r,
                              'load-test reversal', 'OPS_MANUAL', 'SYS', 'pgbench');
