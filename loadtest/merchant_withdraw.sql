-- pgbench: MERCHANT WITHDRAW (from settlement of a random merchant group)
\set g random(1, :ngroup)
\set amt random(50000, 2000000)
\set r random(1, 2000000000)
SELECT post_merchant_withdraw('LTG'||lpad((:g)::text,2,'0'), :amt,
                              'PB-MW-' || :client_id || '-' || :r, NULL, true, 'MOBILE', 'pgbench');
