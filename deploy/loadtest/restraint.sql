-- pgbench: RESTRAINT add + remove (hold/lien lifecycle) on a random consumer wallet.
-- Self-contained and balance-neutral: places a DEBIT/PLEDGE hold (locks PLEDGED_AMT
-- into TOTAL_RESTRAINED_AMT, shrinking CALC_BAL) then releases it (recomputes the
-- aggregate back). Exercises add_restraint + release_restraint and the WLT_ACCT
-- rollup/version bumps under concurrency. \gset threads the new restraint_id into
-- the release. Counts as 1 pgbench transaction = 2 SP calls.
\set a random(1, :nwallet)
\set amt random(1000, 100000)
\set r random(1, 2000000000)
SELECT restraint_id AS rid FROM add_restraint('LT'||lpad((:a)::text,10,'0'), 'DEBIT', 'PLEDGE', :amt, CURRENT_DATE, NULL, 'PB-RST-' || :client_id || '-' || :r, NULL, 'pgbench') \gset
SELECT release_restraint(:rid, 'load-test release', 'pgbench');
