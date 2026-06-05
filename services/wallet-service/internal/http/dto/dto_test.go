package dto

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestOk_Shape(t *testing.T) {
	body, err := json.Marshal(Ok(map[string]any{"foo": "bar", "n": 42}, "req-abc"))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("unmarshal: %v\nbody=%s", err, body)
	}
	if got["errorCode"] != SuccessErrorCode {
		t.Errorf("errorCode = %v, want %q", got["errorCode"], SuccessErrorCode)
	}
	if got["errorMessage"] != SuccessErrorMessage {
		t.Errorf("errorMessage = %v, want %q", got["errorMessage"], SuccessErrorMessage)
	}
	if got["trace_id"] != "req-abc" {
		t.Errorf("trace_id = %v, want req-abc", got["trace_id"])
	}
	if got["timestamp"] == "" || got["timestamp"] == nil {
		t.Error("timestamp is empty")
	}
	data, ok := got["data"].(map[string]any)
	if !ok {
		t.Fatalf("data is not an object: %v (body=%s)", got["data"], body)
	}
	if data["foo"] != "bar" {
		t.Errorf("data.foo = %v, want \"bar\"", data["foo"])
	}
	// 00000 mirrors SQLSTATE successful_completion — so the client always
	// parses errorCode the same way regardless of outcome.
	if !strings.HasPrefix(SuccessErrorCode, "00000") {
		t.Errorf("SuccessErrorCode = %q, want \"00000\"", SuccessErrorCode)
	}
}

func TestOk_NilData_OmitsField(t *testing.T) {
	body, err := json.Marshal(Ok(nil, "req-1"))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(body), `"data"`) {
		t.Errorf("body should omit \"data\" when nil (omitempty): %s", body)
	}
}
