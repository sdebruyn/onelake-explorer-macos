// Package fabric is the HTTP client for the Microsoft Fabric REST API
// (https://api.fabric.microsoft.com). OFE uses it for discovery only —
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
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/api"
)

// defaultBaseURL is the canonical Fabric REST endpoint. Override via
// Options.BaseURL only for tests.
const defaultBaseURL = "https://api.fabric.microsoft.com"

// defaultHTTPTimeout is the per-request timeout when the caller does
// not supply a custom *http.Client.
const defaultHTTPTimeout = 30 * time.Second

// defaultMaxAttempts is how many times api.Do retries a single request.
const defaultMaxAttempts = 4

// Options configures Client construction. Zero values pick sensible
// defaults; only TokenProvider is required.
type Options struct {
	// TokenProvider yields the Bearer token. Required.
	TokenProvider api.TokenProvider
	// HTTPClient overrides the underlying *http.Client. Default has a 30s timeout.
	HTTPClient *http.Client
	// BaseURL overrides the Fabric REST endpoint. Default https://api.fabric.microsoft.com.
	BaseURL string
	// MaxAttempts caps retries for 429 / 5xx. Default 4.
	MaxAttempts int
}

// Client is the Fabric REST client. Construct with New. All methods
// are safe for concurrent use.
type Client struct {
	tp          api.TokenProvider
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
		c.http = &http.Client{Timeout: defaultHTTPTimeout}
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

// listAllPages walks paginated Fabric collections until the
// continuationToken is empty, returning the concatenated values.
func listAllPages[T any](ctx context.Context, c *Client, alias, p string, query url.Values) ([]T, error) {
	var all []T
	q := url.Values{}
	for k, v := range query {
		q[k] = v
	}
	for {
		resp, err := c.doJSON(ctx, alias, http.MethodGet, p+queryString(q), nil)
		if err != nil {
			return nil, err
		}
		var page pageResponse[T]
		if err := json.NewDecoder(resp.Body).Decode(&page); err != nil {
			_ = resp.Body.Close()
			return nil, fmt.Errorf("fabric: decode page: %w", err)
		}
		_ = resp.Body.Close()

		all = append(all, page.Value...)
		if page.ContinuationToken == "" {
			return all, nil
		}
		q.Set("continuationToken", page.ContinuationToken)
		slog.Debug("fabric: following pagination",
			"path", p,
			"received", len(all),
		)
	}
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
