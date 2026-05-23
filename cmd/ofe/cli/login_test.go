package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
)

func TestSanitiseAliasStripsInvalidChars(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"work", "work"},
		{"con toso", "contoso"},
		{"contoso.onmicrosoft.com", "contoso.onmicrosoft.com"},
		{"foo@bar.com", "foobar.com"},
		{".leading-dot", "leading-dot"},
		{"--start", "start"},
		{"héllo", "hllo"},
		{"", ""},
	}
	for _, tc := range cases {
		got := sanitiseAlias(tc.in)
		if got != tc.want {
			t.Errorf("sanitiseAlias(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestSuggestAliasPrefersTenantName(t *testing.T) {
	got := suggestAlias(auth.Account{TenantName: "Contoso", Username: "sam@contoso.com"})
	if got != "Contoso" {
		t.Errorf("suggestAlias = %q, want Contoso", got)
	}
}

func TestSuggestAliasFallsBackToDomain(t *testing.T) {
	got := suggestAlias(auth.Account{Username: "sam@contoso.com"})
	if got != "contoso.com" {
		t.Errorf("suggestAlias = %q, want contoso.com", got)
	}
}

func TestSuggestAliasFinalFallbackIsWork(t *testing.T) {
	got := suggestAlias(auth.Account{})
	if got != "work" {
		t.Errorf("suggestAlias = %q, want work", got)
	}
}

func TestResolveAliasFromFlagSkipsPrompt(t *testing.T) {
	var out bytes.Buffer
	alias, err := resolveAlias(strings.NewReader(""), &out, "team-x", auth.Account{})
	if err != nil {
		t.Fatalf("resolveAlias: %v", err)
	}
	if alias != "team-x" {
		t.Errorf("alias = %q, want team-x", alias)
	}
	if out.Len() != 0 {
		t.Errorf("unexpected output when --account given: %q", out.String())
	}
}

func TestResolveAliasRejectsInvalidFlag(t *testing.T) {
	_, err := resolveAlias(strings.NewReader(""), &bytes.Buffer{}, "bad alias", auth.Account{})
	if err == nil {
		t.Fatal("expected error for invalid --account")
	}
}

func TestResolveAliasUsesPromptedValue(t *testing.T) {
	var out bytes.Buffer
	in := strings.NewReader("client-a\n")
	alias, err := resolveAlias(in, &out, "", auth.Account{Username: "sam@contoso.com"})
	if err != nil {
		t.Fatalf("resolveAlias: %v", err)
	}
	if alias != "client-a" {
		t.Errorf("alias = %q, want client-a", alias)
	}
	if !strings.Contains(out.String(), "Name this account") {
		t.Errorf("expected prompt in output, got %q", out.String())
	}
}

func TestResolveAliasUsesDefaultOnEmptyLine(t *testing.T) {
	var out bytes.Buffer
	in := strings.NewReader("\n")
	alias, err := resolveAlias(in, &out, "", auth.Account{Username: "sam@contoso.com"})
	if err != nil {
		t.Fatalf("resolveAlias: %v", err)
	}
	if alias != "contoso.com" {
		t.Errorf("alias = %q, want contoso.com (suggested default)", alias)
	}
}

func TestResolveAliasLoopsOnInvalidInputThenAccepts(t *testing.T) {
	var out bytes.Buffer
	in := strings.NewReader("bad alias\nclient-a\n")
	alias, err := resolveAlias(in, &out, "", auth.Account{})
	if err != nil {
		t.Fatalf("resolveAlias: %v", err)
	}
	if alias != "client-a" {
		t.Errorf("alias = %q, want client-a", alias)
	}
	if !strings.Contains(out.String(), "Invalid alias") {
		t.Errorf("expected 'Invalid alias' diagnostic, got %q", out.String())
	}
}
