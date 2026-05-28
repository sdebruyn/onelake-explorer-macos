package cli

import (
	"testing"
)

func TestParseDebugRef(t *testing.T) {
	cases := []struct {
		name    string
		input   string
		want    debugRef
		wantErr bool
	}{
		// Happy paths.
		{
			name:  "alias only",
			input: "work:",
			want:  debugRef{alias: "work"},
		},
		{
			name:  "alias with trailing slash only",
			input: "work:/",
			want:  debugRef{alias: "work"},
		},
		{
			name:  "alias + workspace",
			input: "work:/MyWorkspace",
			want:  debugRef{alias: "work", workspace: "MyWorkspace"},
		},
		{
			name:  "alias + workspace + item",
			input: "work:/MyWorkspace/MyLakehouse",
			want:  debugRef{alias: "work", workspace: "MyWorkspace", item: "MyLakehouse"},
		},
		{
			name:  "alias + workspace + item + path",
			input: "work:/MyWorkspace/MyLakehouse/Files/data.csv",
			want:  debugRef{alias: "work", workspace: "MyWorkspace", item: "MyLakehouse", path: "Files/data.csv"},
		},
		{
			name:  "GUID workspace",
			input: "work:/11111111-2222-3333-4444-555555555555/item",
			want:  debugRef{alias: "work", workspace: "11111111-2222-3333-4444-555555555555", item: "item"},
		},

		// Edge cases that must succeed.
		{
			name:  "path with multiple segments beyond item",
			input: "client-a:/WS/LH/dir/sub/file.parquet",
			want:  debugRef{alias: "client-a", workspace: "WS", item: "LH", path: "dir/sub/file.parquet"},
		},

		// Error cases.
		{
			name:    "no colon",
			input:   "work",
			wantErr: true,
		},
		{
			name:    "colon at position 0",
			input:   ":workspace",
			wantErr: true,
		},
		{
			name:    "double slash alias://workspace",
			input:   "work://workspace",
			wantErr: true,
		},
		{
			name:    "triple slash",
			input:   "work:///workspace",
			wantErr: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseDebugRef(tc.input)
			if tc.wantErr {
				if err == nil {
					t.Errorf("parseDebugRef(%q) = %+v, want error", tc.input, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseDebugRef(%q) unexpected error: %v", tc.input, err)
			}
			if got != tc.want {
				t.Errorf("parseDebugRef(%q) = %+v, want %+v", tc.input, got, tc.want)
			}
		})
	}
}
