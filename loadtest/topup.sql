-- pgbench: TOPUP (credit a random consumer wallet from Treasury)
\set a random(1, :nwallet)
\set amt random(10000, 1000000)
\set r random(1, 2000000000)
SELECT post_topup('LT'||lpad((:a)::text,10,'0'), :amt,
                  'PB-TU-' || :client_id || '-' || :r, '{}'::jsonb, 'TREASURY', 'pgbench');
