package api

import (
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

func mkResp(status int, body string, header http.Header) *http.Response {
	if header == nil {
		header = http.Header{}
	}
	return &http.Response{
		StatusCode: status,
		Status:     http.StatusText(status),
		Body:       io.NopCloser(strings.NewReader(body)),
		Header:     header,
	}
}

func TestFromResponse_Success(t *testing.T) {
	if err := FromResponse(mkResp(200, "", nil)); err != nil {
		t.Fatalf("200 should be nil, got %v", err)
	}
	if err := FromResponse(mkResp(204, "", nil)); err != nil {
		t.Fatalf("204 should be nil, got %v", err)
	}
}

func TestFromResponse_TypedSentinels(t *testing.T) {
	cases := []struct {
		status   int
		sentinel error
	}{
		{401, ErrUnauthorized},
		{403, ErrForbidden},
		{404, ErrNotFound},
		{409, ErrConflict},
		{412, ErrPreconditionFailed},
		{429, ErrThrottled},
		{500, ErrServerError},
		{503, ErrServerError},
	}
	for _, c := range cases {
		err := FromResponse(mkResp(c.status, "boom", nil))
		if !errors.Is(err, c.sentinel) {
			t.Errorf("status %d: errors.Is(_, %v) = false, want true", c.status, c.sentinel)
		}
	}
}

func TestFromResponse_UntypedStatus(t *testing.T) {
	// 418 is not specifically mapped; we still return an APIError.
	err := FromResponse(mkResp(418, "teapot", nil))
	var ae *APIError
	if !errors.As(err, &ae) {
		t.Fatalf("expected *APIError, got %T", err)
	}
	if ae.StatusCode != 418 {
		t.Errorf("StatusCode = %d, want 418", ae.StatusCode)
	}
	if !strings.Contains(ae.Error(), "418") {
		t.Errorf("Error()=%q does not contain 418", ae.Error())
	}
}

func TestParseRetryAfter_Seconds(t *testing.T) {
	h := http.Header{"Retry-After": []string{"7"}}
	err := FromResponse(mkResp(429, "", h))
	var ae *APIError
	if !errors.As(err, &ae) {
		t.Fatalf("want APIError")
	}
	if ae.RetryAfter != 7*time.Second {
		t.Errorf("RetryAfter = %v, want 7s", ae.RetryAfter)
	}
}

func TestParseRetryAfter_HTTPDate(t *testing.T) {
	future := time.Now().Add(5 * time.Second).UTC().Format(http.TimeFormat)
	h := http.Header{"Retry-After": []string{future}}
	err := FromResponse(mkResp(503, "", h))
	var ae *APIError
	if !errors.As(err, &ae) {
		t.Fatalf("want APIError")
	}
	// Allow ±2s slack since we parsed against wall clock.
	if ae.RetryAfter < 2*time.Second || ae.RetryAfter > 6*time.Second {
		t.Errorf("RetryAfter = %v, want ~5s", ae.RetryAfter)
	}
}

func TestParseRetryAfter_Garbage(t *testing.T) {
	h := http.Header{"Retry-After": []string{"not-a-date"}}
	err := FromResponse(mkResp(429, "", h))
	var ae *APIError
	if !errors.As(err, &ae) {
		t.Fatalf("want APIError")
	}
	if ae.RetryAfter != 0 {
		t.Errorf("RetryAfter = %v, want 0", ae.RetryAfter)
	}
}
