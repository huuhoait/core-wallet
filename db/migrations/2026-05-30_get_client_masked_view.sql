-- =============================================================================
-- 2026-05-30_get_client_masked_view.sql — Incremental migration
-- (tracked incremental migrations live in db/migrations/)
-- =============================================================================
-- Adds the masked client-profile view backing GET /v1/clients/:client_no.
-- The unmasked profile (GET /v1/ops/clients/:client_no) reads the raw tables
-- directly as wallet_pii_ro (already granted SELECT ON ALL TABLES) — no DB
-- object needed for it. Idempotent: safe to re-run.
-- =============================================================================
\set ON_ERROR_STOP on
BEGIN;

-- Masked client profile. Runs with the view OWNER's privileges (security_invoker
-- off, PG default) so wallet_app reads masked output without direct SELECT on
-- raw CLIENT_NAME / GLOBAL_ID (those column grants are deliberately withheld).
CREATE OR REPLACE VIEW v_client_masked AS
SELECT
  c.CLIENT_NO,
  regexp_replace(c.CLIENT_NAME, '(^.).*(.$)', '\1***\2')        AS client_name_masked,
  c.CLIENT_TYPE,
  c.GLOBAL_ID_TYPE,
  CASE WHEN c.GLOBAL_ID IS NULL THEN NULL
       ELSE '****' || right(c.GLOBAL_ID, 4) END                AS global_id_masked,
  c.COUNTRY_LOC, c.COUNTRY_CITIZEN, c.CLIENT_GRP, c.ACCT_EXEC,
  c.STATUS,
  i.BIRTH_DATE, i.SEX, i.RESIDENT_STATUS,
  k.KYC_TIER,
  k.STATUS                                                     AS kyc_status,
  k.RISK_LEVEL,
  CASE WHEN k.PHONE_NO_HASH IS NULL THEN NULL
       ELSE '09xxxxx' || right(encode(k.PHONE_NO_HASH, 'hex'), 3) END AS phone_masked,
  k.VERIFIED_AT
FROM FM_CLIENT c
LEFT JOIN FM_CLIENT_INDVL i ON i.CLIENT_NO = c.CLIENT_NO
LEFT JOIN LATERAL (
  SELECT k2.KYC_TIER, k2.STATUS, k2.RISK_LEVEL, k2.PHONE_NO_HASH, k2.VERIFIED_AT
    FROM WLT_CLIENT_KYC k2
   WHERE k2.CLIENT_NO = c.CLIENT_NO
   ORDER BY k2.KYC_ID DESC
   LIMIT 1
) k ON true;

-- wallet_app may read the masked view (guarded only where the role exists).
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wallet_app') THEN
    GRANT SELECT ON v_client_masked TO wallet_app;
  END IF;
END $$;

COMMIT;
