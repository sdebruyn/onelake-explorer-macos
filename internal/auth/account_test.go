package auth

import (
	"strings"
	"testing"
)

func TestValidateAlias(t *testing.T) {
	cases := []struct {
		name    string
		alias   string
		wantErr bool
	}{
		{name: "simple", alias: "work", wantErr: false},
		{name: "with digits", alias: "client42", wantErr: false},
		{name: "with dash", alias: "client-a", wantErr: false},
		{name: "with underscore", alias: "client_a", wantErr: false},
		{name: "with dot", alias: "team.lead", wantErr: false},
		{name: "mixed case", alias: "MyAccount", wantErr: false},
		{name: "single char", alias: "a", wantErr: false},
		{name: "max length", alias: strings.Repeat("a", MaxAliasLength), wantErr: false},

		{name: "empty", alias: "", wantErr: true},
		{name: "too long", alias: strings.Repeat("a", MaxAliasLength+1), wantErr: true},
		{name: "forward slash", alias: "work/dev", wantErr: true},
		{name: "back slash", alias: "work\\dev", wantErr: true},
		{name: "space", alias: "my work", wantErr: true},
		{name: "tab", alias: "my\twork", wantErr: true},
		{name: "newline", alias: "work\n", wantErr: true},
		{name: "null byte", alias: "work\x00", wantErr: true},
		{name: "control char", alias: "work\x01", wantErr: true},
		{name: "non-ascii", alias: "wérk", wantErr: true},
		{name: "emoji", alias: "work\xf0\x9f\x98\x80", wantErr: true},
		{name: "colon", alias: "work:dev", wantErr: true},
		{name: "at sign", alias: "user@host", wantErr: true},
		{name: "dot dot", alias: "..", wantErr: false}, // explicitly allowed by charset rules; path traversal isn't this layer's concern
		{name: "leading dash", alias: "-work", wantErr: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := ValidateAlias(tc.alias)
			if tc.wantErr && err == nil {
				t.Errorf("ValidateAlias(%q) = nil, want error", tc.alias)
			}
			if !tc.wantErr && err != nil {
				t.Errorf("ValidateAlias(%q) = %v, want nil", tc.alias, err)
			}
		})
	}
}
