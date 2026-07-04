package repo

// Integration tests for the onboarding flow (US-1.1 / US-1.2 / US-1.7). They run
// the real stored procedures against a live PostgreSQL and then read the tables
// back to prove the data was persisted correctly (flat FM_CLIENT_KYC columns,
// extra_data, the zero-balance wallet, and the audit trail).
//
// They connect as the `postgres` superuser (the SPs are SECURITY DEFINER, but the
// assertions SELECT base tables that wallet_app cannot read directly). Override
// the DSN with WALLET_TEST_DSN. If no DB is reachable the tests SKIP, so
// `go test ./...` stays green without a running stack:
//
//	docker compose up -d
//	go test -run Integration ./internal/repo/...

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/ewallet-pg/wallet-service/internal/domain"
)

const defaultTestDSN = "postgres://postgres:postgres_dev_only@localhost:5432/wallet?sslmode=disable"

var itSeq atomic.Int64

// uniqN returns a process-unique number used to build collision-free phones /
// global ids across runs (each row is cleaned up, but separate runs may overlap).
func uniqN() int64 { return time.Now().UnixNano() + itSeq.Add(1) }

// phoneFrom builds a valid VN mobile (^0[0-9]{9}$) from n.
func phoneFrom(n int64) string { return fmt.Sprintf("09%08d", n%100000000) }

func sha256hex(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

// itRepo dials the test DB or skips. Returns the repo + raw pool for assertions.
func itRepo(t *testing.T) (*PgWalletRepo, *pgxpool.Pool) {
	t.Helper()
	dsn := os.Getenv("WALLET_TEST_DSN")
	if dsn == "" {
		dsn = defaultTestDSN
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Skipf("no test DB (%v) — set WALLET_TEST_DSN or run `docker compose up -d`", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		t.Skipf("test DB unreachable (%v) — run `docker compose up -d`", err)
	}
	t.Cleanup(pool.Close)
	// PII DEK: KMS-injected via PII_DEK in prod; a fixed dev key here. Passed to the
	// repo so encrypt/decrypt SPs get app.pii_dek per-TX — NOT via ALTER DATABASE.
	dek := os.Getenv("PII_DEK")
	if dek == "" {
		dek = "dev-test-pii-dek-do-not-use-in-prod"
	}
	return NewPgWalletRepo(pool, nil, nil, 5*time.Second, 3*time.Second, 1, dek), pool
}

// dropClient removes a client and all its rows at test end (audit log included).
func dropClient(t *testing.T, pool *pgxpool.Pool, clientNo string) {
	t.Cleanup(func() {
		ctx := context.Background()
		for _, q := range []string{
			`DELETE FROM wlt_acct WHERE client_no = $1`,
			`DELETE FROM fm_client_kyc WHERE client_no = $1`,
			`DELETE FROM fm_client_audit_log WHERE client_no = $1`,
			`DELETE FROM fm_client WHERE client_no = $1`,
		} {
			_, _ = pool.Exec(ctx, q, clientNo)
		}
	})
}

func itAudit() domain.AuditContext {
	return domain.AuditContext{Actor: "it-tester", Channel: domain.ChannelAPI, RequestID: "it-req-1"}
}

// wantDomainCode asserts err is a *domain.Error with the given code + HTTP status.
func wantDomainCode(t *testing.T, err error, code string, status int) {
	t.Helper()
	if err == nil {
		t.Fatalf("expected error %s, got nil", code)
	}
	var de *domain.Error
	if !errors.As(err, &de) {
		t.Fatalf("expected *domain.Error, got %T: %v", err, err)
	}
	if de.Code != code {
		t.Errorf("code = %q, want %q", de.Code, code)
	}
	if de.HTTPStatus != status {
		t.Errorf("status = %d, want %d (code %s)", de.HTTPStatus, status, de.Code)
	}
}

// TestOnboardClient_PersistsAllData_Integration — US-1.1/1.15: onboarding writes
// FM_CLIENT, the centralized FM_CLIENT_KYC (flat identity columns + extra_data +
// hashed phone), a zero-balance WLT_ACCT, and an audit row — all in one TX.
func TestOnboardClient_PersistsAllData_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()

	n := uniqN()
	phone := phoneFrom(n)
	gid := fmt.Sprintf("IT%013d", n)
	in := domain.OnboardInput{
		ClientName: "NGUYEN VAN TEST", ClientType: "IND", Phone: phone,
		GlobalID: gid, GlobalIDType: "CCCD", Email: "it@test.vn",
		CountryLoc: "VN", CountryCitizen: "VN", AcctType: "CONSUMER", Ccy: "VND",
		BirthDate: "1990-05-15", Sex: "M",
		DateIssue: "2018-01-02", ExpireDate: "2030-01-01", PlaceIssue: "CA Ha Noi",
		ExtraData: map[string]any{"surname": "NGUYEN", "given_name": "VAN TEST"},
		Audit:     itAudit(),
	}
	res, err := repo.OnboardClient(ctx, in)
	if err != nil {
		t.Fatalf("OnboardClient: %v", err)
	}
	dropClient(t, pool, res.ClientNo)

	// Returned result.
	if res.KycTier != "1" || res.KycStatus != "A" {
		t.Errorf("result tier/status = %s/%s, want 1/A", res.KycTier, res.KycStatus)
	}
	if res.Balance != "0" || res.Ccy != "VND" || res.AcctNo == "" || res.InternalKey == 0 {
		t.Errorf("unexpected result: %+v", res)
	}

	// FM_CLIENT.
	var cName, cType, cGid, cStatus string
	if err := pool.QueryRow(ctx,
		`SELECT client_name, client_type, global_id, status FROM fm_client WHERE client_no = $1`, res.ClientNo).
		Scan(&cName, &cType, &cGid, &cStatus); err != nil {
		t.Fatalf("fm_client read: %v", err)
	}
	if cName != in.ClientName || cType != "IND" || cGid != gid || cStatus != "A" {
		t.Errorf("fm_client = {name:%q type:%q gid:%q status:%q}", cName, cType, cGid, cStatus)
	}

	// FM_CLIENT_KYC — flat identity columns + extra_data + phone hash.
	var tier, status, kGid, kGidType, sex, surname, givenName, phoneHash string
	var birth, dIssue, expire *time.Time
	var place *string
	if err := pool.QueryRow(ctx, `
		SELECT kyc_tier, status, global_id, global_id_type, sex, birthdate, date_issue, expire_date, place_issue,
		       extra_data->>'surname', extra_data->>'given_name', encode(phone_no_hash, 'hex')
		  FROM fm_client_kyc WHERE client_no = $1`, res.ClientNo).
		Scan(&tier, &status, &kGid, &kGidType, &sex, &birth, &dIssue, &expire, &place,
			&surname, &givenName, &phoneHash); err != nil {
		t.Fatalf("fm_client_kyc read: %v", err)
	}
	if tier != "1" || status != "A" {
		t.Errorf("kyc tier/status = %s/%s, want 1/A", tier, status)
	}
	if kGid != gid || kGidType != "CCCD" || sex != "M" {
		t.Errorf("kyc identity = {gid:%q type:%q sex:%q}", kGid, kGidType, sex)
	}
	if birth == nil || birth.Format("2006-01-02") != "1990-05-15" {
		t.Errorf("birthdate = %v, want 1990-05-15", birth)
	}
	if dIssue == nil || dIssue.Format("2006-01-02") != "2018-01-02" {
		t.Errorf("date_issue = %v, want 2018-01-02", dIssue)
	}
	if expire == nil || expire.Format("2006-01-02") != "2030-01-01" {
		t.Errorf("expire_date = %v, want 2030-01-01", expire)
	}
	if place == nil || *place != "CA Ha Noi" {
		t.Errorf("place_issue = %v, want 'CA Ha Noi'", place)
	}
	if surname != "NGUYEN" || givenName != "VAN TEST" {
		t.Errorf("extra_data names = {%q,%q}", surname, givenName)
	}
	if phoneHash != sha256hex(phone) {
		t.Errorf("phone_no_hash = %s, want sha256(%s)=%s", phoneHash, phone, sha256hex(phone))
	}

	// WLT_ACCT — opened, zero balance, standalone.
	var aStatus, aType, aCcy string
	var balZero bool
	if err := pool.QueryRow(ctx,
		`SELECT acct_status, acct_type, ccy, actual_bal = 0 FROM wlt_acct WHERE acct_no = $1`, res.AcctNo).
		Scan(&aStatus, &aType, &aCcy, &balZero); err != nil {
		t.Fatalf("wlt_acct read: %v", err)
	}
	if aStatus != "A" || aType != "CONSUMER" || aCcy != "VND" || !balZero {
		t.Errorf("wlt_acct = {status:%q type:%q ccy:%q balZero:%v}", aStatus, aType, aCcy, balZero)
	}

	// Audit policy (US-8.5): client-master auditing records CHANGES, not creation.
	// Onboarding is an INSERT, so it must leave NO row in FM_CLIENT_AUDIT_LOG.
	var auditRows int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM fm_client_audit_log WHERE client_no = $1`, res.ClientNo).
		Scan(&auditRows); err != nil {
		t.Fatalf("fm_client_audit_log read: %v", err)
	}
	if auditRows != 0 {
		t.Errorf("onboarding INSERT must not be audited, got %d audit row(s)", auditRows)
	}
}

// TestOnboardClient_Org_Integration — US-1.7: CORP/MER require business_reg_no +
// legal_rep (BR-09); when present, the org bag is persisted in extra_data.
func TestOnboardClient_Org_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()

	// Missing org fields → 422 ORG_FIELDS_REQUIRED, nothing persisted.
	missing := domain.OnboardInput{
		ClientName: "ACME LLC", ClientType: "CORP", Phone: phoneFrom(uniqN()),
		AcctType: "MERCHANT", Audit: itAudit(),
	}
	_, err := repo.OnboardClient(ctx, missing)
	wantDomainCode(t, err, domain.CodeOrgFieldsRequired, 422)

	// With org fields → success; extra_data carries them.
	n := uniqN()
	ok := domain.OnboardInput{
		ClientName: "ACME LLC", ClientType: "CORP", Phone: phoneFrom(n),
		GlobalID: fmt.Sprintf("BRN%010d", n), GlobalIDType: "BRN", AcctType: "MERCHANT", Ccy: "VND",
		ExtraData: map[string]any{
			"business_reg_no": "BRN-1",
			"legal_rep":       map[string]any{"name": "Tran B", "id_no": "079000"},
			"ubo":             []any{map[string]any{"name": "Tran B", "pct": 100}},
		},
		Audit: itAudit(),
	}
	res, err := repo.OnboardClient(ctx, ok)
	if err != nil {
		t.Fatalf("OnboardClient(CORP): %v", err)
	}
	dropClient(t, pool, res.ClientNo)

	var brn, repName, cType string
	if err := pool.QueryRow(ctx, `
		SELECT c.client_type, k.extra_data->>'business_reg_no', k.extra_data#>>'{legal_rep,name}'
		  FROM fm_client c JOIN fm_client_kyc k ON k.client_no = c.client_no
		 WHERE c.client_no = $1`, res.ClientNo).Scan(&cType, &brn, &repName); err != nil {
		t.Fatalf("org read: %v", err)
	}
	if cType != "CORP" || brn != "BRN-1" || repName != "Tran B" {
		t.Errorf("org persisted = {type:%q brn:%q rep:%q}", cType, brn, repName)
	}
}

// TestOnboardClient_DuplicatePhone_Integration — US-1.1: a second registration
// with the same phone is rejected and does not create a second client.
func TestOnboardClient_DuplicatePhone_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()

	phone := phoneFrom(uniqN())
	first := domain.OnboardInput{
		ClientName: "FIRST", ClientType: "IND", Phone: phone,
		GlobalID: fmt.Sprintf("IT%013d", uniqN()), Audit: itAudit(),
	}
	res, err := repo.OnboardClient(ctx, first)
	if err != nil {
		t.Fatalf("first OnboardClient: %v", err)
	}
	dropClient(t, pool, res.ClientNo)

	dup := first
	dup.ClientName = "SECOND"
	dup.GlobalID = fmt.Sprintf("IT%013d", uniqN())
	_, err = repo.OnboardClient(ctx, dup)
	wantDomainCode(t, err, domain.CodePhoneAlreadyRegistered, 409)

	var n int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM fm_client_kyc WHERE phone_no_hash = digest($1, 'sha256')`, phone).Scan(&n); err != nil {
		t.Fatalf("count by phone: %v", err)
	}
	if n != 1 {
		t.Errorf("clients with phone %s = %d, want 1", phone, n)
	}
}

// TestUpdateKYC_Integration — US-1.2: update_kyc raises the tier, persists the
// eKYC fields, merges extra_data, and stamps verified_at on reaching tier >= 2.
func TestUpdateKYC_Integration(t *testing.T) {
	repo, pool := itRepo(t)
	ctx := context.Background()

	n := uniqN()
	res, err := repo.OnboardClient(ctx, domain.OnboardInput{
		ClientName: "KYC SUBJECT", ClientType: "IND", Phone: phoneFrom(n),
		GlobalID: fmt.Sprintf("IT%013d", n), Audit: itAudit(),
	})
	if err != nil {
		t.Fatalf("OnboardClient: %v", err)
	}
	dropClient(t, pool, res.ClientNo)

	score := 0.97
	kres, err := repo.UpdateKYC(ctx, domain.KycUpdateInput{
		ClientNo: res.ClientNo, KycTier: "2", Status: "A", RiskLevel: "M",
		EkycProvider: "VNG", EkycRef: "R-123", FaceMatchScore: &score, LivenessResult: "PASS",
		ExtraData: map[string]any{"occupation_code": "ENG"},
		Audit:     itAudit(),
	})
	if err != nil {
		t.Fatalf("UpdateKYC: %v", err)
	}
	if kres.KycTier != "2" || kres.Status != "A" || kres.RiskLevel != "M" || kres.VerifiedAt == nil {
		t.Errorf("UpdateKYC result = %+v", kres)
	}

	var tier, provider, ref, liveness, occ string
	var faceScore *float64
	var verifiedAt *time.Time
	if err := pool.QueryRow(ctx, `
		SELECT kyc_tier, ekyc_provider, ekyc_ref, face_match_score, liveness_result,
		       verified_at, extra_data->>'occupation_code'
		  FROM fm_client_kyc WHERE client_no = $1`, res.ClientNo).
		Scan(&tier, &provider, &ref, &faceScore, &liveness, &verifiedAt, &occ); err != nil {
		t.Fatalf("kyc read: %v", err)
	}
	if tier != "2" || provider != "VNG" || ref != "R-123" || liveness != "PASS" {
		t.Errorf("eKYC fields = {tier:%q prov:%q ref:%q live:%q}", tier, provider, ref, liveness)
	}
	if faceScore == nil || *faceScore < 0.969 || *faceScore > 0.971 {
		t.Errorf("face_match_score = %v, want ~0.97", faceScore)
	}
	if verifiedAt == nil {
		t.Errorf("verified_at not stamped on tier 2")
	}
	if occ != "ENG" {
		t.Errorf("extra_data merge: occupation_code = %q, want ENG", occ)
	}

	// Audit policy (US-8.5): the UPDATE is recorded in FM_CLIENT_AUDIT_LOG,
	// attributed to the actor from the audit GUCs (INSERTs are not audited).
	var updRows int
	var changedBy string
	if err := pool.QueryRow(ctx, `
		SELECT count(*), coalesce(max(changed_by), '')
		  FROM fm_client_audit_log
		 WHERE client_no = $1 AND table_name = 'fm_client_kyc' AND operation = 'UPDATE'`, res.ClientNo).
		Scan(&updRows, &changedBy); err != nil {
		t.Fatalf("fm_client_audit_log read: %v", err)
	}
	if updRows == 0 {
		t.Errorf("expected an UPDATE audit row for fm_client_kyc")
	}
	if changedBy != "it-tester" {
		t.Errorf("audit changed_by = %q, want it-tester", changedBy)
	}
}
