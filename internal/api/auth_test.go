package api

import (
	"context"
	"errors"
	"net/http"
	"testing"
)

type stubTP struct {
	tok string
	err error
}

func (s stubTP) Token(ctx context.Context, alias string) (string, error) { return s.tok, s.err }

func TestInjectBearer_Success(t *testing.T) {
	req, _ := http.NewRequest("GET", "https://example.com/", nil)
	if err := InjectBearer(context.Background(), req, stubTP{tok: "tok-123"}, "work"); err != nil {
		t.Fatalf("InjectBearer: %v", err)
	}
	if got := req.Header.Get("Authorization"); got != "Bearer tok-123" {
		t.Errorf("Authorization = %q, want Bearer tok-123", got)
	}
}

func TestInjectBearer_NilProvider(t *testing.T) {
	req, _ := http.NewRequest("GET", "https://example.com/", nil)
	if err := InjectBearer(context.Background(), req, nil, "work"); err == nil {
		t.Error("nil provider should error")
	}
}

func TestInjectBearer_ProviderError(t *testing.T) {
	want := errors.New("token boom")
	req, _ := http.NewRequest("GET", "https://example.com/", nil)
	err := InjectBearer(context.Background(), req, stubTP{err: want}, "work")
	if !errors.Is(err, want) {
		t.Errorf("err = %v, want wrapping %v", err, want)
	}
}
