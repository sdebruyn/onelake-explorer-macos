package telemetry

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestParseConnectionString_Happy(t *testing.T) {
	t.Parallel()
	const cs = "InstrumentationKey=00000000-0000-0000-0000-000000000001;IngestionEndpoint=https://westeurope.in.applicationinsights.azure.com/;LiveEndpoint=https://westeurope.livediagnostics.monitor.azure.com/"
	endpoint, iKey, err := ParseConnectionString(cs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if iKey != "00000000-0000-0000-0000-000000000001" {
		t.Errorf("iKey = %q, want guid", iKey)
	}
	if endpoint != "https://westeurope.in.applicationinsights.azure.com/" {
		t.Errorf("endpoint = %q", endpoint)
	}
}

func TestParseConnectionString_DefaultEndpointWhenMissing(t *testing.T) {
	t.Parallel()
	endpoint, iKey, err := ParseConnectionString("InstrumentationKey=abc")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if iKey != "abc" {
		t.Errorf("iKey = %q", iKey)
	}
	if !strings.HasPrefix(endpoint, "https://dc.services.visualstudio.com") {
		t.Errorf("endpoint = %q, want default", endpoint)
	}
	if !strings.HasSuffix(endpoint, "/") {
		t.Errorf("endpoint must end with /, got %q", endpoint)
	}
}

func TestParseConnectionString_AppendsTrailingSlash(t *testing.T) {
	t.Parallel()
	endpoint, _, err := ParseConnectionString("InstrumentationKey=abc;IngestionEndpoint=https://example.com")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if endpoint != "https://example.com/" {
		t.Errorf("endpoint = %q, want trailing slash", endpoint)
	}
}

func TestParseConnectionString_CaseInsensitiveKeys(t *testing.T) {
	t.Parallel()
	endpoint, iKey, err := ParseConnectionString("instrumentationkey=guid;INGESTIONENDPOINT=https://example.com/")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if iKey != "guid" || endpoint != "https://example.com/" {
		t.Errorf("parsed wrong values: iKey=%q endpoint=%q", iKey, endpoint)
	}
}

func TestParseConnectionString_Errors(t *testing.T) {
	t.Parallel()
	cases := map[string]string{
		"empty":           "",
		"only-whitespace": "   ",
		"missing-key":     "IngestionEndpoint=https://example.com/",
		"malformed-pair":  "noequals",
	}
	for name, cs := range cases {
		t.Run(name, func(t *testing.T) {
			if _, _, err := ParseConnectionString(cs); err == nil {
				t.Errorf("expected error for %q", cs)
			}
		})
	}
}

func TestAppInsightsSink_Send_PostsExpectedShape(t *testing.T) {
	t.Parallel()
	type capture struct {
		method      string
		path        string
		contentType string
		body        []byte
	}
	got := make(chan capture, 1)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got <- capture{
			method:      r.Method,
			path:        r.URL.Path,
			contentType: r.Header.Get("Content-Type"),
			body:        b,
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"itemsReceived":1,"itemsAccepted":1,"errors":[]}`))
	}))
	defer srv.Close()

	sink, err := NewAppInsightsSink(AppInsightsOptions{
		ConnectionString: "InstrumentationKey=test-ikey;IngestionEndpoint=" + srv.URL + "/",
		InstallID:        "install-xyz",
		AppVersion:       "2026.05.1",
	})
	if err != nil {
		t.Fatalf("NewAppInsightsSink: %v", err)
	}

	success := true
	ev := Event{
		Time:             time.Date(2026, 5, 23, 12, 0, 0, 0, time.UTC),
		Name:             "file_download",
		TenantID:         "tenant-guid",
		AccountAliasHash: "deadbeef",
		DurationMs:       423,
		Success:          &success,
		BytesTransferred: 1024,
		CommonProps: map[string]string{
			"installId":  "install-xyz",
			"appVersion": "2026.05.1",
			"platform":   "darwin",
			"arch":       "arm64",
			"osVersion":  "14.5.1",
		},
	}

	if err := sink.Send(context.Background(), []Event{ev}); err != nil {
		t.Fatalf("Send: %v", err)
	}

	cap := <-got
	if cap.method != http.MethodPost {
		t.Errorf("method = %q, want POST", cap.method)
	}
	if cap.path != "/v2/track" {
		t.Errorf("path = %q, want /v2/track", cap.path)
	}
	if !strings.HasPrefix(cap.contentType, "application/json") {
		t.Errorf("content-type = %q", cap.contentType)
	}

	var envs []map[string]any
	if err := json.Unmarshal(cap.body, &envs); err != nil {
		t.Fatalf("body not JSON array: %v body=%s", err, cap.body)
	}
	if len(envs) != 1 {
		t.Fatalf("envelope count = %d, want 1", len(envs))
	}
	env := envs[0]
	if env["name"] != "Microsoft.ApplicationInsights.Event" {
		t.Errorf("envelope name = %v", env["name"])
	}
	if env["iKey"] != "test-ikey" {
		t.Errorf("iKey = %v", env["iKey"])
	}
	if env["time"] != "2026-05-23T12:00:00.000Z" {
		t.Errorf("time = %v", env["time"])
	}
	tags, _ := env["tags"].(map[string]any)
	if tags["ai.cloud.role"] != "ofem" {
		t.Errorf("ai.cloud.role = %v", tags["ai.cloud.role"])
	}
	if tags["ai.cloud.roleInstance"] != "install-xyz" {
		t.Errorf("ai.cloud.roleInstance = %v", tags["ai.cloud.roleInstance"])
	}
	if tags["ai.internal.sdkVersion"] != "ofem:2026.05.1" {
		t.Errorf("ai.internal.sdkVersion = %v", tags["ai.internal.sdkVersion"])
	}
	data, _ := env["data"].(map[string]any)
	if data["baseType"] != "EventData" {
		t.Errorf("baseType = %v", data["baseType"])
	}
	baseData, _ := data["baseData"].(map[string]any)
	if baseData["name"] != "file_download" {
		t.Errorf("baseData.name = %v", baseData["name"])
	}
	props, _ := baseData["properties"].(map[string]any)
	if props["tenantId"] != "tenant-guid" {
		t.Errorf("tenantId prop = %v", props["tenantId"])
	}
	if props["installId"] != "install-xyz" {
		t.Errorf("installId prop = %v", props["installId"])
	}
	if props["success"] != "true" {
		t.Errorf("success prop = %v", props["success"])
	}
	meas, _ := baseData["measurements"].(map[string]any)
	if meas["durationMs"].(float64) != 423 {
		t.Errorf("durationMs = %v", meas["durationMs"])
	}
	if meas["bytesTransferred"].(float64) != 1024 {
		t.Errorf("bytesTransferred = %v", meas["bytesTransferred"])
	}
}

func TestAppInsightsSink_Send_PartialAcceptIsError(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"itemsReceived":2,"itemsAccepted":1,"errors":[{"index":1,"statusCode":400,"message":"bad"}]}`))
	}))
	defer srv.Close()

	sink, err := NewAppInsightsSink(AppInsightsOptions{
		ConnectionString: "InstrumentationKey=k;IngestionEndpoint=" + srv.URL + "/",
	})
	if err != nil {
		t.Fatalf("NewAppInsightsSink: %v", err)
	}
	err = sink.Send(context.Background(), []Event{{Name: "a"}, {Name: "b"}})
	if err == nil {
		t.Fatal("expected error on partial accept")
	}
	if !strings.Contains(err.Error(), "1/2") {
		t.Errorf("error should mention 1/2, got: %v", err)
	}
}

func TestAppInsightsSink_Send_Non2xxIsError(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "nope", http.StatusInternalServerError)
	}))
	defer srv.Close()
	sink, _ := NewAppInsightsSink(AppInsightsOptions{
		ConnectionString: "InstrumentationKey=k;IngestionEndpoint=" + srv.URL + "/",
	})
	err := sink.Send(context.Background(), []Event{{Name: "x"}})
	if err == nil || !strings.Contains(err.Error(), "500") {
		t.Errorf("expected HTTP 500 error, got %v", err)
	}
}

func TestAppInsightsSink_Send_EmptyBatchIsNoop(t *testing.T) {
	t.Parallel()
	called := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		called = true
	}))
	defer srv.Close()
	sink, _ := NewAppInsightsSink(AppInsightsOptions{
		ConnectionString: "InstrumentationKey=k;IngestionEndpoint=" + srv.URL + "/",
	})
	if err := sink.Send(context.Background(), nil); err != nil {
		t.Errorf("empty batch should be a no-op, got %v", err)
	}
	if called {
		t.Errorf("empty batch should not hit the network")
	}
}
