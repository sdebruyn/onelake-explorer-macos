// Package fabric is the HTTP client for the Microsoft Fabric REST API
// (https://api.fabric.microsoft.com). OFEM uses it for discovery only —
// listing workspaces, items, and Fabric workspace-folders, plus
// fetching a single item's metadata. File I/O happens through
// internal/onelake against the DFS endpoint.
package fabric

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/api"
	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
)

// defaultBaseURL is the canonical Fabric REST endpoint. Override via
// Options.BaseURL only for tests.
const defaultBaseURL = "https://api.fabric.microsoft.com"

// defaultResponseHeaderTimeout caps the time we wait for the response
// headers after the request is written. We deliberately do NOT set
// Client.Timeout — the Fabric REST endpoints we use today all return
// small JSON bodies, but keeping the semantics aligned with the
// OneLake client means body deadlines are always under context
// control, never a fixed wall-clock budget.
const defaultResponseHeaderTimeout = 30 * time.Second

// defaultMaxAttempts is how many times api.Do retries a single request.
const defaultMaxAttempts = 4

// maxPaginationPages caps how many pages listAllPages will walk before
// giving up. Cheap insurance against a misbehaving server that keeps
// returning a non-empty continuation forever.
const maxPaginationPages = 1000

// Options configures Client construction. Zero values pick sensible
// defaults; only TokenProvider is required.
type Options struct {
	// TokenProvider yields the Bearer token. Required.
	TokenProvider auth.TokenProvider
	// HTTPClient overrides the underlying *http.Client. The default
	// caps the response-header wait at 30s but does NOT set
	// Client.Timeout — body deadlines are under context control.
	HTTPClient *http.Client
	// BaseURL overrides the Fabric REST endpoint. Default https://api.fabric.microsoft.com.
	BaseURL string
	// MaxAttempts caps retries for 429 / 5xx. Default 4.
	MaxAttempts int
}

// Client is the Fabric REST client. Construct with New. All methods
// are safe for concurrent use.
type Client struct {
	tp          auth.TokenProvider
	http        *http.Client
	baseURL     string
	maxAttempts int
}

// New builds a Client from Options.
func New(opts Options) *Client {
	c := &Client{
		tp:          opts.TokenProvider,
		http:        opts.HTTPClient,
		baseURL:     opts.BaseURL,
		maxAttempts: opts.MaxAttempts,
	}
	if c.http == nil {
		c.http = defaultHTTPClient()
	}
	if c.baseURL == "" {
		c.baseURL = defaultBaseURL
	}
	if c.maxAttempts < 1 {
		c.maxAttempts = defaultMaxAttempts
	}
	return c
}

// Workspace is a Fabric workspace returned by ListWorkspaces.
type Workspace struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	Type        string `json:"type"`
	Description string `json:"description,omitempty"`
	CapacityID  string `json:"capacityId,omitempty"`
	DomainID    string `json:"domainId,omitempty"`
}

// Item is a Fabric item (Lakehouse, Warehouse, Notebook, …) inside a workspace.
type Item struct {
	ID             string `json:"id"`
	DisplayName    string `json:"displayName"`
	Type           string `json:"type"`
	Description    string `json:"description,omitempty"`
	WorkspaceID    string `json:"workspaceId"`
	ParentFolderID string `json:"folderId,omitempty"`
}

// Folder is a Fabric workspace-folder. Distinct from item folders, which
// live inside an item and are accessed through the DFS API.
type Folder struct {
	ID             string `json:"id"`
	DisplayName    string `json:"displayName"`
	WorkspaceID    string `json:"workspaceId"`
	ParentFolderID string `json:"parentFolderId,omitempty"`
}

// pageResponse is the common shape of a paged Fabric collection.
type pageResponse[T any] struct {
	Value             []T    `json:"value"`
	ContinuationToken string `json:"continuationToken,omitempty"`
	ContinuationURI   string `json:"continuationUri,omitempty"`
}

// ListWorkspaces returns every workspace the principal can see, following
// continuationToken pagination to the end.
func (c *Client) ListWorkspaces(ctx context.Context, alias string) ([]Workspace, error) {
	return listAllPages[Workspace](ctx, c, alias, "/v1/workspaces", nil)
}

// ListItems returns all items in the given workspace.
func (c *Client) ListItems(ctx context.Context, alias, workspaceID string) ([]Item, error) {
	if workspaceID == "" {
		return nil, fmt.Errorf("fabric: workspaceID required")
	}
	p := path.Join("/v1/workspaces", workspaceID, "items")
	return listAllPages[Item](ctx, c, alias, p, nil)
}

// ListFolders returns the Fabric workspace-folders inside the given
// workspace. These are the workspace-level folders that organize items;
// they are unrelated to the item-internal folders served by the DFS API.
func (c *Client) ListFolders(ctx context.Context, alias, workspaceID string) ([]Folder, error) {
	if workspaceID == "" {
		return nil, fmt.Errorf("fabric: workspaceID required")
	}
	p := path.Join("/v1/workspaces", workspaceID, "folders")
	return listAllPages[Folder](ctx, c, alias, p, nil)
}

// GetItem fetches a single item by ID.
func (c *Client) GetItem(ctx context.Context, alias, workspaceID, itemID string) (Item, error) {
	if workspaceID == "" || itemID == "" {
		return Item{}, fmt.Errorf("fabric: workspaceID and itemID required")
	}
	p := path.Join("/v1/workspaces", workspaceID, "items", itemID)
	resp, err := c.doJSON(ctx, alias, http.MethodGet, p, nil)
	if err != nil {
		return Item{}, err
	}
	defer func() { _ = resp.Body.Close() }()

	var item Item
	if err := json.NewDecoder(resp.Body).Decode(&item); err != nil {
		return Item{}, fmt.Errorf("fabric: decode item: %w", err)
	}
	return item, nil
}

// defaultHTTPClient builds the *http.Client used when the caller does
// not supply one. The transport bounds DNS / connect / TLS handshake
// and waits up to defaultResponseHeaderTimeout for response headers,
// but does NOT cap body streaming. Callers control the overall
// deadline through context.
func defaultHTTPClient() *http.Client {
	var t *http.Transport
	if base, ok := http.DefaultTransport.(*http.Transport); ok {
		t = base.Clone()
	} else {
		t = &http.Transport{}
	}
	t.ResponseHeaderTimeout = defaultResponseHeaderTimeout
	return &http.Client{
		Transport: t,
		// Intentionally no Timeout: see defaultResponseHeaderTimeout.
	}
}

// listAllPages walks paginated Fabric collections, honoring either
// continuationToken (token replayed on the original path) or
// continuationUri (absolute URL — issued as-is). Stops when the server
// returns neither.
//
// Three guards keep a misbehaving server from looping forever:
//   - hard cap of maxPaginationPages pages,
//   - identical continuation token twice in a row,
//   - identical continuation URI twice in a row.
//
// Any of those conditions returns a clear error.
func listAllPages[T any](ctx context.Context, c *Client, alias, p string, query url.Values) ([]T, error) {
	var all []T
	q := url.Values{}
	for k, v := range query {
		q[k] = v
	}

	nextPath := p + queryString(q)
	var prevToken, prevURI string
	for page := 0; ; page++ {
		if page >= maxPaginationPages {
			return nil, fmt.Errorf("fabric: pagination exceeded %d pages for %s", maxPaginationPages, p)
		}

		resp, err := c.doJSON(ctx, alias, http.MethodGet, nextPath, nil)
		if err != nil {
			return nil, err
		}
		var pr pageResponse[T]
		if err := json.NewDecoder(resp.Body).Decode(&pr); err != nil {
			_ = resp.Body.Close()
			return nil, fmt.Errorf("fabric: decode page: %w", err)
		}
		_ = resp.Body.Close()

		all = append(all, pr.Value...)

		switch {
		case pr.ContinuationToken != "":
			if pr.ContinuationToken == prevToken {
				return nil, fmt.Errorf("fabric: server returned identical continuationToken twice for %s", p)
			}
			prevToken = pr.ContinuationToken
			prevURI = ""
			q.Set("continuationToken", pr.ContinuationToken)
			nextPath = p + queryString(q)
		case pr.ContinuationURI != "":
			if pr.ContinuationURI == prevURI {
				return nil, fmt.Errorf("fabric: server returned identical continuationUri twice for %s", p)
			}
			prevURI = pr.ContinuationURI
			prevToken = ""
			// Translate the absolute URI into a path-and-query relative
			// to the configured base. If the URI is on a different host
			// the request will fail loudly upstream.
			next, err := relativeToBase(c.baseURL, pr.ContinuationURI)
			if err != nil {
				return nil, fmt.Errorf("fabric: continuationUri %q: %w", pr.ContinuationURI, err)
			}
			nextPath = next
		default:
			return all, nil
		}

		slog.Debug("fabric: following pagination",
			"path", p,
			"received", len(all),
			"page", page+1,
		)
	}
}

// relativeToBase turns an absolute continuationUri into a path+query
// string relative to base. Returns an error if the URI cannot be
// parsed or points to a different host than base.
func relativeToBase(base, raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", fmt.Errorf("parse: %w", err)
	}
	if u.Host != "" {
		bu, err := url.Parse(base)
		if err != nil {
			return "", fmt.Errorf("parse base: %w", err)
		}
		if !strings.EqualFold(u.Host, bu.Host) {
			return "", fmt.Errorf("continuationUri host %q does not match base %q", u.Host, bu.Host)
		}
	}
	out := u.Path
	if u.RawQuery != "" {
		out += "?" + u.RawQuery
	}
	return out, nil
}

// queryString renders url.Values with a leading "?", or "" if empty.
func queryString(q url.Values) string {
	if len(q) == 0 {
		return ""
	}
	return "?" + q.Encode()
}

// doJSON issues a Fabric JSON request with bearer auth and retry. The
// caller owns the returned body and must close it.
func (c *Client) doJSON(ctx context.Context, alias, method, pathAndQuery string, body interface{}) (*http.Response, error) {
	full := c.baseURL + pathAndQuery

	var bodyReader io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("fabric: encode body: %w", err)
		}
		bodyReader = bytes.NewReader(buf)
	}

	req, err := http.NewRequestWithContext(ctx, method, full, bodyReader)
	if err != nil {
		return nil, fmt.Errorf("fabric: new request: %w", err)
	}
	if bodyReader != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Accept", "application/json")

	if err := api.InjectBearer(ctx, req, c.tp, alias); err != nil {
		return nil, err
	}

	slog.Debug("fabric: request", "method", method, "path", pathAndQuery)
	return api.Do(ctx, c.http, req, c.maxAttempts)
}
