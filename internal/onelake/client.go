// Package onelake is the HTTP client for the OneLake DFS endpoint
// (https://onelake.dfs.fabric.microsoft.com). It speaks the
// ADLS Gen2 REST dialect for file I/O against Fabric items.
//
// Workspace and item are addressed by GUID (preferred — immutable
// across renames). Paths are item-relative, e.g. "Files/data/foo.csv".
package onelake

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/sdebruyn/onelake-explorer-macos/internal/api"
)

const (
	defaultBaseURL     = "https://onelake.dfs.fabric.microsoft.com"
	defaultHTTPTimeout = 30 * time.Second
	defaultMaxAttempts = 4
	// chunkSize is the body size of one append call in Write. 4 MiB is
	// well under Azure's per-append limit (100 MiB) and lines up neatly
	// with typical filesystem block sizes.
	chunkSize = 4 * 1024 * 1024
	// maxPaginationPages caps how many pages ListPath will walk before
	// giving up. Cheap insurance against a misbehaving server that keeps
	// returning the same continuation header forever.
	maxPaginationPages = 1000
)

// Options configures Client construction. Only TokenProvider is required.
type Options struct {
	TokenProvider api.TokenProvider
	HTTPClient    *http.Client
	BaseURL       string
	MaxAttempts   int
}

// Client is the OneLake DFS client. Construct with New. Methods are
// safe for concurrent use.
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

// PathEntry is one row of a directory listing. Names are workspace-rooted
// (e.g. "<itemGUID>/Files/data.csv") as returned by the DFS API.
type PathEntry struct {
	Name          string    `json:"name"`
	IsDirectory   bool      `json:"isDirectory,omitempty"`
	ContentLength int64     `json:"contentLength,omitempty"`
	ETag          string    `json:"etag,omitempty"`
	LastModified  time.Time `json:"lastModified,omitempty"`
}

// rawEntry is the wire-format row; DFS returns strings for everything.
// We translate to PathEntry which has typed fields.
type rawEntry struct {
	Name          string `json:"name"`
	IsDirectory   string `json:"isDirectory,omitempty"`
	ContentLength string `json:"contentLength,omitempty"`
	ETag          string `json:"etag,omitempty"`
	LastModified  string `json:"lastModified,omitempty"`
}

// ListResult is the full set of entries returned by ListPath. ListPath
// fully resolves pagination internally, so callers never need a
// continuation cursor.
type ListResult struct {
	Entries []PathEntry
}

// PathProperties is the parsed HEAD response on a file or directory.
type PathProperties struct {
	IsDirectory   bool
	ContentLength int64
	ETag          string
	LastModified  time.Time
	ContentType   string
}

// ListPath enumerates a directory inside a OneLake item. If recursive
// is true, every descendant is returned in a single (paginated) stream.
// The directory parameter is the item-relative path; pass "" to list
// the item root.
//
// Pagination is fully resolved before returning — repeated requests
// follow the `continuation` query parameter until the server stops
// sending one.
func (c *Client) ListPath(ctx context.Context, alias, workspaceGUID, itemGUID, directory string, recursive bool) (*ListResult, error) {
	if workspaceGUID == "" || itemGUID == "" {
		return nil, fmt.Errorf("onelake: workspaceGUID and itemGUID required")
	}

	dir := joinItemPath(itemGUID, directory)

	out := &ListResult{}
	cont := ""
	for page := 0; ; page++ {
		if page >= maxPaginationPages {
			return nil, fmt.Errorf("onelake: pagination exceeded %d pages for %s", maxPaginationPages, dir)
		}

		q := url.Values{}
		q.Set("resource", "filesystem")
		q.Set("recursive", strconv.FormatBool(recursive))
		q.Set("directory", dir)
		if cont != "" {
			q.Set("continuation", cont)
		}

		// DFS list is rooted at the filesystem (= workspace).
		u := "/" + url.PathEscape(workspaceGUID) + "?" + q.Encode()
		resp, err := c.doRequest(ctx, alias, http.MethodGet, u, nil, nil)
		if err != nil {
			return nil, err
		}

		var pageBody struct {
			Paths []rawEntry `json:"paths"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&pageBody); err != nil {
			_ = resp.Body.Close()
			return nil, fmt.Errorf("onelake: decode list: %w", err)
		}
		nextCont := resp.Header.Get("x-ms-continuation")
		_ = resp.Body.Close()

		for _, p := range pageBody.Paths {
			out.Entries = append(out.Entries, convertEntry(p))
		}
		if nextCont == "" {
			return out, nil
		}
		if nextCont == cont {
			return nil, fmt.Errorf("onelake: server returned identical continuation token twice for %s", dir)
		}
		cont = nextCont
		slog.Debug("onelake: list pagination",
			"workspace", workspaceGUID, "item", itemGUID, "dir", directory,
			"received", len(out.Entries),
			"page", page+1,
		)
	}
}

// convertEntry translates a rawEntry (DFS string-typed) to PathEntry.
func convertEntry(r rawEntry) PathEntry {
	pe := PathEntry{
		Name: r.Name,
		ETag: r.ETag,
	}
	if r.IsDirectory == "true" {
		pe.IsDirectory = true
	}
	if r.ContentLength != "" {
		if n, err := strconv.ParseInt(r.ContentLength, 10, 64); err == nil {
			pe.ContentLength = n
		}
	}
	if r.LastModified != "" {
		// DFS returns RFC1123 or RFC1123Z; try both.
		if t, err := http.ParseTime(r.LastModified); err == nil {
			pe.LastModified = t
		}
	}
	return pe
}

// GetProperties does a DFS HEAD on a single path. The returned struct
// is sourced from the response headers — DFS does not return a body.
func (c *Client) GetProperties(ctx context.Context, alias, workspaceGUID, itemGUID, path string) (*PathProperties, error) {
	if workspaceGUID == "" || itemGUID == "" {
		return nil, fmt.Errorf("onelake: workspaceGUID and itemGUID required")
	}
	u := pathURL(workspaceGUID, itemGUID, path, nil)
	resp, err := c.doRequest(ctx, alias, http.MethodHead, u, nil, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	pp := &PathProperties{
		ETag:        resp.Header.Get("ETag"),
		ContentType: resp.Header.Get("Content-Type"),
	}
	if v := resp.Header.Get("x-ms-resource-type"); v == "directory" {
		pp.IsDirectory = true
	}
	if v := resp.Header.Get("Content-Length"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			pp.ContentLength = n
		}
	}
	if v := resp.Header.Get("Last-Modified"); v != "" {
		if t, err := http.ParseTime(v); err == nil {
			pp.LastModified = t
		}
	}
	return pp, nil
}

// Read returns the file body, optionally restricted by a byte Range.
// Use rangeStart=0, rangeEnd=-1 to skip Range and read the whole file.
// The caller MUST close the returned ReadCloser.
func (c *Client) Read(ctx context.Context, alias, workspaceGUID, itemGUID, path string, rangeStart, rangeEnd int64) (io.ReadCloser, error) {
	if workspaceGUID == "" || itemGUID == "" {
		return nil, fmt.Errorf("onelake: workspaceGUID and itemGUID required")
	}
	u := pathURL(workspaceGUID, itemGUID, path, nil)
	var extra http.Header
	if rangeStart > 0 || rangeEnd >= 0 {
		extra = http.Header{}
		var spec string
		if rangeEnd >= 0 {
			spec = fmt.Sprintf("bytes=%d-%d", rangeStart, rangeEnd)
		} else {
			spec = fmt.Sprintf("bytes=%d-", rangeStart)
		}
		extra.Set("Range", spec)
	}
	resp, err := c.doRequest(ctx, alias, http.MethodGet, u, nil, extra)
	if err != nil {
		return nil, err
	}
	return resp.Body, nil
}

// Write uploads content to path using the create + append + flush
// pattern. The body is consumed in chunks of chunkSize so memory use
// stays bounded regardless of file size.
//
// size must equal the total bytes provided by content. If content
// supplies fewer bytes the call returns io.ErrUnexpectedEOF; more
// bytes are ignored once size is reached.
func (c *Client) Write(ctx context.Context, alias, workspaceGUID, itemGUID, path string, content io.Reader, size int64) error {
	if workspaceGUID == "" || itemGUID == "" {
		return fmt.Errorf("onelake: workspaceGUID and itemGUID required")
	}
	if path == "" {
		return fmt.Errorf("onelake: path required")
	}
	if size < 0 {
		return fmt.Errorf("onelake: size must be >= 0")
	}

	// 1. create file (no content yet).
	createURL := pathURL(workspaceGUID, itemGUID, path, url.Values{"resource": []string{"file"}})
	resp, err := c.doRequest(ctx, alias, http.MethodPut, createURL, nil, nil)
	if err != nil {
		return fmt.Errorf("onelake: create file: %w", err)
	}
	_ = resp.Body.Close()

	// 2. append in chunks.
	var pos int64
	buf := make([]byte, chunkSize)
	remaining := size
	for remaining > 0 {
		want := int64(len(buf))
		if want > remaining {
			want = remaining
		}
		n, rerr := io.ReadFull(content, buf[:want])
		if rerr == io.ErrUnexpectedEOF || rerr == io.EOF {
			return fmt.Errorf("onelake: short read at offset %d: %w", pos, io.ErrUnexpectedEOF)
		}
		if rerr != nil {
			return fmt.Errorf("onelake: read chunk: %w", rerr)
		}

		appendQ := url.Values{
			"action":   []string{"append"},
			"position": []string{strconv.FormatInt(pos, 10)},
		}
		appendURL := pathURL(workspaceGUID, itemGUID, path, appendQ)
		body := bytes.NewReader(buf[:n])
		extra := http.Header{"Content-Length": []string{strconv.Itoa(n)}}
		resp, err := c.doRequest(ctx, alias, http.MethodPatch, appendURL, body, extra)
		if err != nil {
			return fmt.Errorf("onelake: append at %d: %w", pos, err)
		}
		_ = resp.Body.Close()

		pos += int64(n)
		remaining -= int64(n)
	}

	// 3. flush.
	flushQ := url.Values{
		"action":   []string{"flush"},
		"position": []string{strconv.FormatInt(size, 10)},
	}
	flushURL := pathURL(workspaceGUID, itemGUID, path, flushQ)
	resp, err = c.doRequest(ctx, alias, http.MethodPatch, flushURL, nil, nil)
	if err != nil {
		return fmt.Errorf("onelake: flush: %w", err)
	}
	_ = resp.Body.Close()
	return nil
}

// CreateDirectory creates a directory inside the item.
func (c *Client) CreateDirectory(ctx context.Context, alias, workspaceGUID, itemGUID, path string) error {
	if workspaceGUID == "" || itemGUID == "" {
		return fmt.Errorf("onelake: workspaceGUID and itemGUID required")
	}
	if path == "" {
		return fmt.Errorf("onelake: path required")
	}
	u := pathURL(workspaceGUID, itemGUID, path, url.Values{"resource": []string{"directory"}})
	resp, err := c.doRequest(ctx, alias, http.MethodPut, u, nil, nil)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	return nil
}

// Delete removes a file or directory. If recursive is true, all
// descendants of a directory are removed too; otherwise non-empty
// directories yield a 409 from the server.
func (c *Client) Delete(ctx context.Context, alias, workspaceGUID, itemGUID, path string, recursive bool) error {
	if workspaceGUID == "" || itemGUID == "" {
		return fmt.Errorf("onelake: workspaceGUID and itemGUID required")
	}
	if path == "" {
		return fmt.Errorf("onelake: path required")
	}
	q := url.Values{}
	if recursive {
		q.Set("recursive", "true")
	}
	u := pathURL(workspaceGUID, itemGUID, path, q)
	resp, err := c.doRequest(ctx, alias, http.MethodDelete, u, nil, nil)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	return nil
}

// pathURL builds a request URL for an item-relative path. workspaceGUID
// is the filesystem; itemGUID is the first path segment; relPath is
// joined under it. extra adds query parameters. Path segments are
// individually escaped with url.PathEscape so that reserved characters
// (spaces, '#', '?', '%', '+', …) in legitimate OneLake names are
// preserved as literal bytes instead of being interpreted as fragment
// or query delimiters.
func pathURL(workspaceGUID, itemGUID, relPath string, extra url.Values) string {
	p := "/" + url.PathEscape(workspaceGUID) + "/" + joinItemPath(itemGUID, relPath)
	if len(extra) == 0 {
		return p
	}
	return p + "?" + extra.Encode()
}

// joinItemPath joins an item-relative path onto the item GUID,
// normalizing leading and trailing slashes. Each path segment is
// individually URL-escaped so reserved characters do not bleed into
// the URL syntax; the '/' separators between segments are preserved.
func joinItemPath(itemGUID, relPath string) string {
	relPath = strings.Trim(relPath, "/")
	if relPath == "" {
		return url.PathEscape(itemGUID)
	}
	segs := strings.Split(relPath, "/")
	escaped := make([]string, 0, len(segs)+1)
	escaped = append(escaped, url.PathEscape(itemGUID))
	for _, s := range segs {
		escaped = append(escaped, url.PathEscape(s))
	}
	return strings.Join(escaped, "/")
}

// doRequest builds a request against the DFS base, injects the token,
// then runs it through api.Do for retries. The caller owns the response
// body and must close it.
func (c *Client) doRequest(ctx context.Context, alias, method, pathAndQuery string, body io.Reader, extraHeaders http.Header) (*http.Response, error) {
	full := c.baseURL + pathAndQuery
	req, err := http.NewRequestWithContext(ctx, method, full, body)
	if err != nil {
		return nil, fmt.Errorf("onelake: new request: %w", err)
	}
	for k, vs := range extraHeaders {
		for _, v := range vs {
			req.Header.Set(k, v)
		}
	}
	req.Header.Set("x-ms-version", "2021-08-06")
	if err := api.InjectBearer(ctx, req, c.tp, alias); err != nil {
		return nil, err
	}
	slog.Debug("onelake: request", "method", method, "path", pathAndQuery)
	return api.Do(ctx, c.http, req, c.maxAttempts)
}
