-- pgbench: TRANSFER (in-book, fee TRFOUT) between two distinct random wallets
\set a random(1, :nwallet)
\set b ((:a % :nwallet) + 1)
\set amt random(1000, 500000)
\set r random(1, 2000000000)
SELECT post_transfer('LT'||lpad((:a)::text,10,'0'), 'LT'||lpad((:b)::text,10,'0'), :amt,
                     'PB-TR-' || :client_id || '-' || :r, 'TRFOUT', '{}'::jsonb, 'MOBILE', 'pgbench');
