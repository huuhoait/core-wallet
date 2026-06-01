-- pgbench: MERCHANT TOPUP (a consumer pays a merchant → credits group SETTLEMENT)
-- Money flows INTO a merchant: post_transfer from a random consumer wallet to a
-- random group's settlement account (the only on-ledger merchant-credit path —
-- post_topup rejects non-STANDALONE; shards are fed by sweep only). TRFOUT charges
-- the payer a fee, modelling a fee-bearing merchant collection.
\set a random(1, :nwallet)
\set g random(1, :ngroup)
\set amt random(10000, 5000000)
\set r random(1, 9000000000)
SELECT post_transfer('LT'||lpad((:a)::text,10,'0'), 'LTGS'||lpad((:g)::text,4,'0'), :amt,
                     'PB-MTU-' || :client_id || '-' || :r, 'TRFOUT', '{}'::jsonb, 'MOBILE', 'pgbench');
