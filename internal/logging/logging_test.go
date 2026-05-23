package logging

import (
	"bytes"
	"strings"
	"testing"
)

func TestParseLevel(t *testing.T) {
	cases := map[string]bool{
		"":        false,
		"info":    false,
		"INFO":    false,
		"debug":   false,
		"warn":    false,
		"warning": false,
		"error":   false,
		"nope":    true, // should error
	}
	for input, wantErr := range cases {
		_, err := parseLevel(input)
		if gotErr := err != nil; gotErr != wantErr {
			t.Errorf("parseLevel(%q): error=%v, wantErr=%v", input, err, wantErr)
		}
	}
}

func TestSetupDaemonJSON(t *testing.T) {
	var buf bytes.Buffer
	logger, err := Setup(Options{Mode: ModeDaemon, Level: "info", Sink: &buf})
	if err != nil {
		t.Fatalf("setup: %v", err)
	}
	logger.Info("hello", "key", "value")
	out := buf.String()
	if !strings.Contains(out, `"msg":"hello"`) {
		t.Errorf("expected JSON log line with msg=hello, got: %s", out)
	}
	if !strings.Contains(out, `"key":"value"`) {
		t.Errorf("expected key=value attribute, got: %s", out)
	}
}
