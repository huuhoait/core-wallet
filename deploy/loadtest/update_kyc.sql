-- pgbench: UPDATE KYC (US-1.2) — submit/refresh eKYC info and (re)set the tier on a
-- random seeded LT consumer (LTC*). Reuses the seeded client pool (no DB growth) and
-- exercises the UPDATE audit path (trg_audit_fm_kyc → FM_CLIENT_AUDIT_LOG; INSERTs are
-- not audited). update_kyc patches FM_CLIENT_KYC (eKYC provider/ref/score/liveness,
-- tier, risk) and merges extra_data; reaching tier >= 2 stamps verified_at.
\set a random(1, :nwallet)
-- tier 2..3 only: KYC updates upgrade/refresh — never downgrade a seeded consumer
-- below tier 2 (that would make it receive-only and 403 a concurrent withdraw).
\set tier random(2, 3)
SELECT update_kyc('LTC'||lpad((:a)::text,9,'0'), (:tier)::text, 'A', 'M',
                  'VNG', 'PB-KYC-'||:client_id||'-'||:a, 0.970, 'PASS',
                  jsonb_build_object('occupation_code','ENG'), 'loadtest');
