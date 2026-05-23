package fabric

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/api"
)

const testBase = "https://api.fabric.microsoft.com"

type mockTokenProvider struct{ tok string }

func (m mockTokenProvider) Token(_ context.Context, _ string) (string, error) {
	return m.tok, nil
}

// newTestClient wires a Client to httpmock against testBase.
func newTestClient(t *testing.T) *Client {
	t.Helper()
	httpmock.Activate()
	t.Cleanup(httpmock.DeactivateAndReset)

	cli := &http.Client{Timeout: 5 * time.Second}
	httpmock.ActivateNonDefault(cli)
	return New(Options{
		TokenProvider: mockTokenProvider{tok: "tok-abc"},
		HTTPClient:    cli,
		BaseURL:       testBase,
		MaxAttempts:   3,
	})
}

func TestListWorkspaces_HappyPath(t *testing.T) {
	c := newTestClient(t)

	httpmock.RegisterResponder("GET", testBase+"/v1/workspaces",
		func(req *http.Request) (*http.Response, error) {
			if got := req.Header.Get("Authorization"); got != "Bearer tok-abc" {
				t.Errorf("Authorization = %q, want Bearer tok-abc", got)
			}
			body := map[string]any{
				"value": []map[string]any{
					{"id": "ws1", "displayName": "Alpha", "type": "Workspace"},
					{"id": "ws2", "displayName": "Beta", "type": "Workspace", "capacityId": "cap1"},
				},
			}
			return httpmock.NewJsonResponse(200, body)
		})

	got, err := c.ListWorkspaces(context.Background(), "work")
	if err != nil {
		t.Fatalf("ListWorkspaces: %v", err)
	}
	if len(got) != 2 || got[0].ID != "ws1" || got[1].CapacityID != "cap1" {
		t.Errorf("unexpected workspaces: %+v", got)
	}
}

func TestListWorkspaces_Pagination(t *testing.T) {
	c := newTestClient(t)

	// First page returns a continuationToken; second page does not.
	page := 0
	httpmock.RegisterResponder("GET", `=~^`+testBase+`/v1/workspaces(\?.*)?$`,
		func(req *http.Request) (*http.Response, error) {
			page++
			switch page {
			case 1:
				if req.URL.Query().Get("continuationToken") != "" {
					t.Errorf("first page got continuationToken=%q, want empty", req.URL.Query().Get("continuationToken"))
				}
				return httpmock.NewJsonResponse(200, map[string]any{
					"value": []map[string]any{
						{"id": "ws1", "displayName": "Alpha", "type": "Workspace"},
					},
					"continuationToken": "tok-page-2",
				})
			case 2:
				if got := req.URL.Query().Get("continuationToken"); got != "tok-page-2" {
					t.Errorf("second page continuationToken = %q, want tok-page-2", got)
				}
				return httpmock.NewJsonResponse(200, map[string]any{
					"value": []map[string]any{
						{"id": "ws2", "displayName": "Beta", "type": "Workspace"},
					},
				})
			default:
				t.Fatalf("unexpected third page request")
				return nil, nil
			}
		})

	got, err := c.ListWorkspaces(context.Background(), "work")
	if err != nil {
		t.Fatalf("ListWorkspaces: %v", err)
	}
	if len(got) != 2 || got[0].ID != "ws1" || got[1].ID != "ws2" {
		t.Errorf("paged result wrong: %+v", got)
	}
	if page != 2 {
		t.Errorf("page count = %d, want 2", page)
	}
}

func TestListItems_HappyPath(t *testing.T) {
	c := newTestClient(t)

	httpmock.RegisterResponder("GET", testBase+"/v1/workspaces/ws1/items",
		httpmock.NewJsonResponderOrPanic(200, map[string]any{
			"value": []map[string]any{
				{"id": "it1", "displayName": "MyLakehouse", "type": "Lakehouse", "workspaceId": "ws1"},
			},
		}))

	got, err := c.ListItems(context.Background(), "work", "ws1")
	if err != nil {
		t.Fatalf("ListItems: %v", err)
	}
	if len(got) != 1 || got[0].Type != "Lakehouse" {
		t.Errorf("unexpected items: %+v", got)
	}
}

func TestListItems_NoWorkspaceID(t *testing.T) {
	c := newTestClient(t)
	if _, err := c.ListItems(context.Background(), "work", ""); err == nil {
		t.Error("expected error for empty workspaceID")
	}
}

func TestListFolders_HappyPath(t *testing.T) {
	c := newTestClient(t)

	httpmock.RegisterResponder("GET", testBase+"/v1/workspaces/ws1/folders",
		httpmock.NewJsonResponderOrPanic(200, map[string]any{
			"value": []map[string]any{
				{"id": "f1", "displayName": "Folder A", "workspaceId": "ws1"},
				{"id": "f2", "displayName": "Sub", "workspaceId": "ws1", "parentFolderId": "f1"},
			},
		}))

	got, err := c.ListFolders(context.Background(), "work", "ws1")
	if err != nil {
		t.Fatalf("ListFolders: %v", err)
	}
	if len(got) != 2 || got[1].ParentFolderID != "f1" {
		t.Errorf("unexpected folders: %+v", got)
	}
}

func TestGetItem_HappyPath(t *testing.T) {
	c := newTestClient(t)

	httpmock.RegisterResponder("GET", testBase+"/v1/workspaces/ws1/items/it1",
		httpmock.NewJsonResponderOrPanic(200, map[string]any{
			"id":          "it1",
			"displayName": "MyLakehouse",
			"type":        "Lakehouse",
			"workspaceId": "ws1",
			"description": "demo",
		}))

	got, err := c.GetItem(context.Background(), "work", "ws1", "it1")
	if err != nil {
		t.Fatalf("GetItem: %v", err)
	}
	if got.ID != "it1" || got.Description != "demo" {
		t.Errorf("unexpected item: %+v", got)
	}
}

func TestGetItem_404(t *testing.T) {
	c := newTestClient(t)

	httpmock.RegisterResponder("GET", testBase+"/v1/workspaces/ws1/items/missing",
		httpmock.NewStringResponder(404, `{"error":"NotFound"}`))

	_, err := c.GetItem(context.Background(), "work", "ws1", "missing")
	if !errors.Is(err, api.ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

func TestListWorkspaces_401(t *testing.T) {
	c := newTestClient(t)
	httpmock.RegisterResponder("GET", testBase+"/v1/workspaces",
		httpmock.NewStringResponder(401, `unauthorized`))
	_, err := c.ListWorkspaces(context.Background(), "work")
	if !errors.Is(err, api.ErrUnauthorized) {
		t.Fatalf("want ErrUnauthorized, got %v", err)
	}
}

func TestListWorkspaces_429RetriedThenSucceeds(t *testing.T) {
	c := newTestClient(t)

	count := 0
	httpmock.RegisterResponder("GET", testBase+"/v1/workspaces",
		func(req *http.Request) (*http.Response, error) {
			count++
			if count < 3 {
				resp := httpmock.NewStringResponse(429, "throttled")
				resp.Header.Set("Retry-After", "0")
				return resp, nil
			}
			return httpmock.NewJsonResponse(200, map[string]any{
				"value": []map[string]any{{"id": "ws1", "displayName": "Alpha"}},
			})
		})

	got, err := c.ListWorkspaces(context.Background(), "work")
	if err != nil {
		t.Fatalf("ListWorkspaces: %v", err)
	}
	if len(got) != 1 {
		t.Errorf("len(got) = %d, want 1", len(got))
	}
	if count != 3 {
		t.Errorf("call count = %d, want 3 (2x 429 + 1x 200)", count)
	}
}

// TestListWorkspaces_FollowsContinuationURI exercises the
// continuationUri branch — admin/search endpoints return a full URL
// instead of a token, and the client must follow it.
func TestListWorkspaces_FollowsContinuationURI(t *testing.T) {
	c := newTestClient(t)

	page := 0
	httpmock.RegisterResponder("GET", `=~^`+testBase+`/v1/workspaces(\?.*)?$`,
		func(req *http.Request) (*http.Response, error) {
			page++
			switch page {
			case 1:
				if req.URL.RawQuery != "" {
					t.Errorf("first page got query=%q, want empty", req.URL.RawQuery)
				}
				return httpmock.NewJsonResponse(200, map[string]any{
					"value": []map[string]any{
						{"id": "ws1", "displayName": "Alpha", "type": "Workspace"},
					},
					"continuationUri": testBase + "/v1/workspaces?cursor=abc",
				})
			case 2:
				if got := req.URL.Query().Get("cursor"); got != "abc" {
					t.Errorf("second page cursor = %q, want abc", got)
				}
				return httpmock.NewJsonResponse(200, map[string]any{
					"value": []map[string]any{
						{"id": "ws2", "displayName": "Beta", "type": "Workspace"},
					},
				})
			default:
				t.Fatalf("unexpected page %d", page)
				return nil, nil
			}
		})

	got, err := c.ListWorkspaces(context.Background(), "work")
	if err != nil {
		t.Fatalf("ListWorkspaces: %v", err)
	}
	if len(got) != 2 || got[0].ID != "ws1" || got[1].ID != "ws2" {
		t.Errorf("paged result wrong: %+v", got)
	}
}

// TestListWorkspaces_ContinuationURIDifferentHost makes sure we refuse
// to chase a URI off the configured Fabric host.
func TestListWorkspaces_ContinuationURIDifferentHost(t *testing.T) {
	c := newTestClient(t)

	httpmock.RegisterResponder("GET", testBase+"/v1/workspaces",
		httpmock.NewJsonResponderOrPanic(200, map[string]any{
			"value":           []map[string]any{{"id": "ws1"}},
			"continuationUri": "https://evil.example.com/v1/workspaces?cursor=x",
		}))

	_, err := c.ListWorkspaces(context.Background(), "work")
	if err == nil {
		t.Fatal("expected error for cross-host continuationUri")
	}
	if !strings.Contains(err.Error(), "does not match base") {
		t.Errorf("unexpected error: %v", err)
	}
}

// TestListWorkspaces_RepeatedContinuationToken protects against a
// runaway server: identical token twice in a row → loud error.
func TestListWorkspaces_RepeatedContinuationToken(t *testing.T) {
	c := newTestClient(t)

	httpmock.RegisterResponder("GET", `=~^`+testBase+`/v1/workspaces(\?.*)?$`,
		httpmock.NewJsonResponderOrPanic(200, map[string]any{
			"value":             []map[string]any{{"id": "ws1"}},
			"continuationToken": "STUCK",
		}))

	_, err := c.ListWorkspaces(context.Background(), "work")
	if err == nil {
		t.Fatal("expected error for repeated continuation token")
	}
	if !strings.Contains(err.Error(), "identical continuationToken") {
		t.Errorf("unexpected error: %v", err)
	}
}

// TestRelativeToBase covers the URI-rewriting helper directly.
func TestRelativeToBase(t *testing.T) {
	base := "https://api.fabric.microsoft.com"
	cases := []struct {
		name    string
		raw     string
		want    string
		wantErr bool
	}{
		{"absolute same host", base + "/v1/workspaces?cursor=abc", "/v1/workspaces?cursor=abc", false},
		{"relative path", "/v1/workspaces?cursor=abc", "/v1/workspaces?cursor=abc", false},
		{"different host", "https://other.example.com/v1/workspaces", "", true},
		{"path-only", "/v1/items", "/v1/items", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := relativeToBase(base, c.raw)
			if c.wantErr {
				if err == nil {
					t.Errorf("want error, got %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestListWorkspaces_429ExhaustsRetries(t *testing.T) {
	c := newTestClient(t)

	count := 0
	httpmock.RegisterResponder("GET", testBase+"/v1/workspaces",
		func(req *http.Request) (*http.Response, error) {
			count++
			resp := httpmock.NewStringResponse(429, "throttled")
			resp.Header.Set("Retry-After", "0")
			return resp, nil
		})

	_, err := c.ListWorkspaces(context.Background(), "work")
	if !errors.Is(err, api.ErrThrottled) {
		t.Fatalf("want ErrThrottled, got %v", err)
	}
	// MaxAttempts is 3 in the test client.
	if count != 3 {
		t.Errorf("call count = %d, want 3 (maxAttempts)", count)
	}
}
