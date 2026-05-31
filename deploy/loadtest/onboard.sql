-- pgbench: ONBOARD (US-1.1) — create a NEW client + centralized FM_CLIENT_KYC row
-- + a zero-balance wallet in one TX (OTP-free onboard_client SP).
--
-- A dedicated sequence (lt_onboard_seq, created by setup.sql / run.sh) gives each
-- call a unique phone ('08'+8 digits) and global_id 'LT-OB-<n>', so calls never
-- collide on the uk_kyc_phone_hash unique index and teardown can scope these rows.
--
-- NOTE: unlike the other scripts this GROWS the DB (a new C* client + 9701* wallet
-- per call — onboard_client mints them from seq_client/seq_acct_no, so they are NOT
-- 'LT'-prefixed). Re-init (docker compose down -v) or run TEARDOWN=1 between heavy
-- runs; teardown scopes them by global_id LIKE 'LT-OB-%'.
SELECT nextval('lt_onboard_seq') AS n \gset
SELECT onboard_client(
  'LoadOnboard '||:n, 'IND', '08'||lpad((:n % 100000000)::text, 8, '0'),
  'LT-OB-'||:n, 'CCCD', NULL, 'VN', 'VN', 'CONSUMER', 'VND',
  DATE '1990-01-01', 'M', NULL, NULL, NULL, '{}'::jsonb, 'loadtest');
