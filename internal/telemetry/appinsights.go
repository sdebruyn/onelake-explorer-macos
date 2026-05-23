package telemetry

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// defaultIngestionTimeout caps each HTTP POST to the App Insights
// endpoint. Telemetry must never block the daemon's hot paths; the
// caller still controls overall cancellation via ctx.
const defaultIngestionTimeout = 30 * time.Second

// AppInsightsSink ships events to the Application Insights v2/track
// ingestion endpoint. Construct via NewAppInsightsSink.
type AppInsightsSink struct {
	endpoint string // e.g. https://westeurope-5.in.applicationinsights.azure.com/
	iKey     string // instrumentation key GUID
	role     string // ai.cloud.role tag (e.g. "ofe")
	instance string // ai.cloud.roleInstance tag (the install ID)
	sdkTag   string // ai.internal.sdkVersion (e.g. "ofe:2026.05.1")
	client   *http.Client
}

// AppInsightsOptions configures NewAppInsightsSink. ConnectionString is
// required; everything else is optional and defaults to sensible values.
type AppInsightsOptions struct {
	ConnectionString string
	InstallID        string        // becomes ai.cloud.roleInstance
	AppVersion       string        // becomes ai.internal.sdkVersion
	HTTPClient       *http.Client  // defaults to &http.Client{Timeout: 30s}
	Timeout          time.Duration // overrides the default HTTP timeout
}

// NewAppInsightsSink parses the connection string and returns a Sink
// ready to POST envelopes.
func NewAppInsightsSink(opts AppInsightsOptions) (*AppInsightsSink, error) {
	endpoint, iKey, err := ParseConnectionString(opts.ConnectionString)
	if err != nil {
		return nil, err
	}

	client := opts.HTTPClient
	if client == nil {
		timeout := opts.Timeout
		if timeout <= 0 {
			timeout = defaultIngestionTimeout
		}
		client = &http.Client{Timeout: timeout}
	}

	sdkTag := "ofe"
	if opts.AppVersion != "" {
		sdkTag = "ofe:" + opts.AppVersion
	}

	return &AppInsightsSink{
		endpoint: endpoint,
		iKey:     iKey,
		role:     "ofe",
		instance: opts.InstallID,
		sdkTag:   sdkTag,
		client:   client,
	}, nil
}

// ParseConnectionString extracts the IngestionEndpoint and
// InstrumentationKey from an App Insights connection string. The string
// format is documented at
// https://learn.microsoft.com/en-us/azure/azure-monitor/app/sdk-connection-string —
// it is a semicolon-separated list of Key=Value pairs (case-insensitive
// keys, opaque values). Whitespace around tokens is tolerated.
func ParseConnectionString(s string) (endpoint, iKey string, err error) {
	if strings.TrimSpace(s) == "" {
		return "", "", fmt.Errorf("telemetry: empty connection string")
	}
	for _, raw := range strings.Split(s, ";") {
		pair := strings.TrimSpace(raw)
		if pair == "" {
			continue
		}
		eq := strings.IndexByte(pair, '=')
		if eq <= 0 {
			return "", "", fmt.Errorf("telemetry: malformed connection-string entry %q", pair)
		}
		key := strings.ToLower(strings.TrimSpace(pair[:eq]))
		val := strings.TrimSpace(pair[eq+1:])
		switch key {
		case "ingestionendpoint":
			endpoint = val
		case "instrumentationkey":
			iKey = val
		}
	}

	if iKey == "" {
		return "", "", fmt.Errorf("telemetry: connection string missing InstrumentationKey")
	}
	if endpoint == "" {
		// The official default when only the InstrumentationKey is
		// provided. Documented in the App Insights connection-string
		// spec.
		endpoint = "https://dc.services.visualstudio.com/"
	}
	if !strings.HasSuffix(endpoint, "/") {
		endpoint += "/"
	}
	return endpoint, iKey, nil
}

// envelope is the on-the-wire shape of an App Insights v2 EventData
// envelope. See docs/telemetry.md for the example payload.
type envelope struct {
	Name string            `json:"name"`
	Time string            `json:"time"`
	IKey string            `json:"iKey"`
	Tags map[string]string `json:"tags"`
	Data envelopeData      `json:"data"`
}

type envelopeData struct {
	BaseType string        `json:"baseType"`
	BaseData eventBaseData `json:"baseData"`
}

type eventBaseData struct {
	Ver          int                `json:"ver"`
	Name         string             `json:"name"`
	Properties   map[string]string  `json:"properties,omitempty"`
	Measurements map[string]float64 `json:"measurements,omitempty"`
}

// trackResponse is the documented shape of a successful v2/track
// response body.
type trackResponse struct {
	ItemsReceived int `json:"itemsReceived"`
	ItemsAccepted int `json:"itemsAccepted"`
	Errors        []struct {
		Index      int    `json:"index"`
		StatusCode int    `json:"statusCode"`
		Message    string `json:"message"`
	} `json:"errors"`
}

// Send POSTs the events to <endpoint>v2/track as a JSON envelope array.
// It returns an error if the HTTP layer fails, if the response is not in
// the 2xx range, or if itemsAccepted is less than the number of events
// we shipped (partial drops).
func (s *AppInsightsSink) Send(ctx context.Context, events []Event) error {
	if len(events) == 0 {
		return nil
	}

	body, err := s.encode(events)
	if err != nil {
		return fmt.Errorf("telemetry: encode envelope: %w", err)
	}

	url := s.endpoint + "v2/track"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("telemetry: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	req.Header.Set("Accept", "application/json")

	resp, err := s.client.Do(req)
	if err != nil {
		return fmt.Errorf("telemetry: post: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("telemetry: ingestion HTTP %d: %s", resp.StatusCode, string(respBody))
	}

	var tr trackResponse
	if len(respBody) > 0 {
		if err := json.Unmarshal(respBody, &tr); err != nil {
			// 2xx with an unparseable body is best-effort: assume the
			// server accepted everything, like the official SDK does.
			return nil
		}
	}
	if tr.ItemsReceived > 0 && tr.ItemsAccepted < len(events) {
		return fmt.Errorf("telemetry: ingestion accepted %d/%d events", tr.ItemsAccepted, len(events))
	}
	return nil
}

// encode serializes events to the v2/track JSON envelope array.
func (s *AppInsightsSink) encode(events []Event) ([]byte, error) {
	envs := make([]envelope, 0, len(events))
	for _, ev := range events {
		envs = append(envs, s.envelopeFor(ev))
	}
	return json.Marshal(envs)
}

func (s *AppInsightsSink) envelopeFor(ev Event) envelope {
	ts := ev.Time
	if ts.IsZero() {
		ts = time.Now().UTC()
	}

	props, meas := splitFields(ev)

	tags := map[string]string{
		"ai.cloud.role":          s.role,
		"ai.internal.sdkVersion": s.sdkTag,
	}
	if s.instance != "" {
		tags["ai.cloud.roleInstance"] = s.instance
	}

	return envelope{
		Name: "Microsoft.ApplicationInsights.Event",
		Time: ts.UTC().Format("2006-01-02T15:04:05.000Z"),
		IKey: s.iKey,
		Tags: tags,
		Data: envelopeData{
			BaseType: "EventData",
			BaseData: eventBaseData{
				Ver:          2,
				Name:         ev.Name,
				Properties:   props,
				Measurements: meas,
			},
		},
	}
}
