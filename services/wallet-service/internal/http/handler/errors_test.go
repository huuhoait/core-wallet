package handler

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/go-playground/validator/v10"

	"github.com/ewallet-pg/wallet-service/internal/domain"
	"github.com/ewallet-pg/wallet-service/internal/http/dto"
	"github.com/ewallet-pg/wallet-service/internal/http/middleware"
)

func init() { gin.SetMode(gin.TestMode) }

func testCtx(method, path string) (*gin.Context, *httptest.ResponseRecorder) {
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(method, path, nil)
	c.Set(middleware.CtxKeyRequestID, "test-rid")
	return c, w
}

func decodeProblem(t *testing.T, w *httptest.ResponseRecorder) dto.ProblemDetails {
	t.Helper()
	if ct := w.Header().Get("Content-Type"); ct != "application/problem+json" {
		t.Errorf("Content-Type = %q, want application/problem+json", ct)
	}
	var p dto.ProblemDetails
	if err := json.Unmarshal(w.Body.Bytes(), &p); err != nil {
		t.Fatalf("body is not valid JSON: %v\nbody=%s", err, w.Body.String())
	}
	return p
}

func TestRenderError_DomainError(t *testing.T) {
	c, w := testCtx(http.MethodPost, "/v1/transactions/transfer")
	renderError(c, domain.NewError(domain.CodeInsufficientFunds,
		http.StatusUnprocessableEntity, "balance 5 < 10", nil))

	if w.Code != http.StatusUnprocessableEntity {
		t.Errorf("status = %d, want 422", w.Code)
	}
	p := decodeProblem(t, w)
	if p.ErrorCode != domain.CodeInsufficientFunds {
		t.Errorf("errorCode = %q, want INSUFFICIENT_FUNDS", p.ErrorCode)
	}
	if p.ErrorMessage == "" {
		t.Error("errorMessage is empty")
	}
	if p.ErrorMessage != "The account balance is not sufficient to cover this transaction" {
		t.Errorf("errorMessage = %q, want stable message", p.ErrorMessage)
	}
	if p.ISO20022Reason != "AM04" {
		t.Errorf("iso20022_reason_code = %q, want AM04", p.ISO20022Reason)
	}
	if p.TransactionStatus != domain.TxStatusRejected {
		t.Errorf("transaction_status = %q, want RJCT", p.TransactionStatus)
	}
	if p.InternalCode != "E4022" {
		t.Errorf("internal_code = %q, want E4022", p.InternalCode)
	}
	if p.TraceID != "test-rid" {
		t.Errorf("trace_id = %q, want test-rid", p.TraceID)
	}
	if p.Instance != "/v1/transactions/transfer" {
		t.Errorf("instance = %q", p.Instance)
	}
	if p.Timestamp == "" {
		t.Error("timestamp is empty")
	}
	if p.Retry == nil || p.Retry.Retryable {
		t.Errorf("retry = %+v, want non-retryable", p.Retry)
	}
}

func TestRenderError_Retriable(t *testing.T) {
	c, w := testCtx(http.MethodPost, "/v1/transactions/transfer")
	renderError(c, domain.NewError(domain.CodeVersionConflict,
		http.StatusConflict, "version mismatch", nil))

	p := decodeProblem(t, w)
	if p.Retry == nil || !p.Retry.Retryable {
		t.Errorf("retry = %+v, want retryable", p.Retry)
	}
	if p.TransactionStatus != domain.TxStatusPending {
		t.Errorf("transaction_status = %q, want PDNG", p.TransactionStatus)
	}
}

func TestRenderError_NonDomainDoesNotLeak(t *testing.T) {
	c, w := testCtx(http.MethodPost, "/v1/transactions/topup")
	renderError(c, errLeaky{})

	if w.Code != http.StatusInternalServerError {
		t.Errorf("status = %d, want 500", w.Code)
	}
	p := decodeProblem(t, w)
	if p.ErrorCode != domain.CodeInternal {
		t.Errorf("errorCode = %q, want INTERNAL_ERROR", p.ErrorCode)
	}
	if strings.Contains(w.Body.String(), "secret-table") {
		t.Errorf("response leaked internal error detail: %s", w.Body.String())
	}
}

type errLeaky struct{}

func (errLeaky) Error() string { return "pq: relation \"secret-table\" does not exist" }

func TestRenderValidationError_FieldErrors(t *testing.T) {
	type sample struct {
		AcctNo string `validate:"required"`
		Amount string `validate:"required"`
	}
	verr := validator.New().Struct(sample{})
	if verr == nil {
		t.Fatal("expected validation to fail")
	}

	c, w := testCtx(http.MethodPost, "/v1/transactions/withdraw")
	renderValidationError(c, verr)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
	p := decodeProblem(t, w)
	if p.ErrorCode != domain.CodeInvalidRequest {
		t.Errorf("errorCode = %q, want INVALID_REQUEST", p.ErrorCode)
	}
	if len(p.Errors) != 2 {
		t.Fatalf("errors len = %d, want 2 (%+v)", len(p.Errors), p.Errors)
	}
	if p.Errors[0].Code != "required" {
		t.Errorf("errors[0].code = %q, want required", p.Errors[0].Code)
	}
}
