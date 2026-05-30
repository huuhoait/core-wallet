-- pgbench: WITHDRAW (to bank, fee WDRAW) from a random consumer wallet
\set a random(1, :nwallet)
\set amt random(50000, 500000)
\set r random(1, 2000000000)
SELECT post_withdraw('LT'||lpad((:a)::text,10,'0'), :amt,
                     'PB-WD-' || :client_id || '-' || :r,
                     'PBEXT-' || :client_id || '-' || :r,
                     'BIDV', '9990000000', '{}'::jsonb, 'MOBILE', 'pgbench');
