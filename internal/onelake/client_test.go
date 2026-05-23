package onelake

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jarcoal/httpmock"

	"github.com/sdebruyn/onelake-explorer-macos/internal/api"
)

const (
	testBase = "https://onelake.dfs.fabric.microsoft.com"
	wsGUID   = "11111111-1111-1111-1111-111111111111"
	itemGUID = "22222222-2222-2222-2222-222222222222"
)

type mockTokenProvider struct{ tok string }

func (m mockTokenProvider) Token(_ context.Context, _ string) (string, error) {
	return m.tok, nil
}

func newTestClient(t *testing.T) *Client {
	t.Helper()
	httpmock.Activate()
	t.Cleanup(httpmock.DeactivateAndReset)
	cli := &http.Client{Timeout: 10 * time.Second}
	httpmock.ActivateNonDefault(cli)
	return New(Options{
		TokenProvider: mockTokenProvider{tok: "tok-abc"},
		HTTPClient:    cli,
		BaseURL:       testBase,
		MaxAttempts:   3,
	})
}

func TestListPath_HappyPath(t *testing.T) {
	c := newTestClient(t)

	httpmock.RegisterResponder("GET", "=~^"+testBase+"/"+wsGUID+`\?.*$`,
		func(req *http.Request) (*http.Response, error) {
			q := req.URL.Query()
			if q.Get("resource") != "filesystem" {
				t.Errorf("resource = %q, want filesystem", q.Get("resource"))
			}
			if q.Get("recursive") != "false" {
				t.Errorf("recursive = %q, want false", q.Get("recursive"))
			}
			if q.Get("directory") != itemGUID+"/Files" {
				t.Errorf("directory = %q, want %s/Files", q.Get("directory"), itemGUID)
			}
			return httpmock.NewJsonResponse(200, map[string]any{
				"paths": []map[string]any{
					{"name": itemGUID + "/Files/a.csv", "contentLength": "12", "etag": "etag-a"},
					{"name": itemGUID + "/Files/sub", "isDirectory": "true"},
				},
			})
		})

	res, err := c.ListPath(context.Background(), "work", wsGUID, itemGUID, "Files", false)
	if err != nil {
		t.Fatalf("ListPath: %v", err)
	}
	if len(res.Entries) != 2 {
		t.Fatalf("len(entries) = %d, want 2", len(res.Entries))
	}
	if res.Entries[0].ContentLength != 12 || res.Entries[0].ETag != "etag-a" {
		t.Errorf("entry[0] = %+v", res.Entries[0])
	}
	if !res.Entries[1].IsDirectory {
		t.Errorf("entry[1] should be a directory: %+v", res.Entries[1])
	}
}

func TestListPath_Pagination(t *testing.T) {
	c := newTestClient(t)

	page := 0
	httpmock.RegisterResponder("GET", "=~^"+testBase+"/"+wsGUID+`\?.*$`,
		func(req *http.Request) (*http.Response, error) {
			page++
			q := req.URL.Query()
			switch page {
			case 1:
				if q.Get("continuation") != "" {
					t.Errorf("page 1 sent continuation=%q", q.Get("continuation"))
				}
				resp := httpmock.NewBytesResponse(200, []byte(`{"paths":[{"name":"`+itemGUID+`/Files/a"}]}`))
				resp.Header.Set("x-ms-continuation", "TOK2")
				return resp, nil
			case 2:
				if q.Get("continuation") != "TOK2" {
					t.Errorf("page 2 continuation = %q, want TOK2", q.Get("continuation"))
				}
				resp := httpmock.NewBytesResponse(200, []byte(`{"paths":[{"name":"`+itemGUID+`/Files/b"}]}`))
				return resp, nil
			default:
				t.Fatalf("unexpected page %d", page)
				return nil, nil
			}
		})

	res, err := c.ListPath(context.Background(), "work", wsGUID, itemGUID, "Files", false)
	if err != nil {
		t.Fatalf("ListPath: %v", err)
	}
	if len(res.Entries) != 2 {
		t.Fatalf("entries = %d, want 2", len(res.Entries))
	}
	if page != 2 {
		t.Errorf("page count = %d, want 2", page)
	}
}

func TestGetProperties_File(t *testing.T) {
	c := newTestClient(t)

	httpmock.RegisterResponder("HEAD", testBase+"/"+wsGUID+"/"+itemGUID+"/Files/a.csv",
		func(req *http.Request) (*http.Response, error) {
			resp := httpmock.NewStringResponse(200, "")
			resp.Header.Set("Content-Length", "1024")
			resp.Header.Set("ETag", `"etag-xyz"`)
			resp.Header.Set("Content-Type", "text/csv")
			resp.Header.Set("Last-Modified", "Mon, 01 Jan 2024 12:00:00 GMT")
			return resp, nil
		})

	pp, err := c.GetProperties(context.Background(), "work", wsGUID, itemGUID, "Files/a.csv")
	if err != nil {
		t.Fatalf("GetProperties: %v", err)
	}
	if pp.ContentLength != 1024 || pp.ETag != `"etag-xyz"` || pp.ContentType != "text/csv" {
		t.Errorf("unexpected props: %+v", pp)
	}
	if pp.LastModified.IsZero() {
		t.Errorf("LastModified is zero")
	}
}

func TestGetProperties_Directory(t *testing.T) {
	c := newTestClient(t)

	httpmock.RegisterResponder("HEAD", testBase+"/"+wsGUID+"/"+itemGUID+"/Files/sub",
		func(req *http.Request) (*http.Response, error) {
			resp := httpmock.NewStringResponse(200, "")
			resp.Header.Set("x-ms-resource-type", "directory")
			return resp, nil
		})

	pp, err := c.GetProperties(context.Background(), "work", wsGUID, itemGUID, "Files/sub")
	if err != nil {
		t.Fatalf("GetProperties: %v", err)
	}
	if !pp.IsDirectory {
		t.Errorf("expected IsDirectory=true")
	}
}

func TestGetProperties_404(t *testing.T) {
	c := newTestClient(t)
	httpmock.RegisterResponder("HEAD", testBase+"/"+wsGUID+"/"+itemGUID+"/missing",
		httpmock.NewStringResponder(404, ""))
	_, err := c.GetProperties(context.Background(), "work", wsGUID, itemGUID, "missing")
	if !errors.Is(err, api.ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

func TestRead_NoRange(t *testing.T) {
	c := newTestClient(t)
	httpmock.RegisterResponder("GET", testBase+"/"+wsGUID+"/"+itemGUID+"/Files/a.csv",
		func(req *http.Request) (*http.Response, error) {
			if req.Header.Get("Range") != "" {
				t.Errorf("Range header should be empty, got %q", req.Header.Get("Range"))
			}
			return httpmock.NewStringResponse(200, "hello"), nil
		})

	rc, err := c.Read(context.Background(), "work", wsGUID, itemGUID, "Files/a.csv", 0, -1)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	defer rc.Close()
	b, _ := io.ReadAll(rc)
	if string(b) != "hello" {
		t.Errorf("body = %q, want hello", b)
	}
}

func TestRead_WithRange(t *testing.T) {
	c := newTestClient(t)
	httpmock.RegisterResponder("GET", testBase+"/"+wsGUID+"/"+itemGUID+"/Files/a.csv",
		func(req *http.Request) (*http.Response, error) {
			if got := req.Header.Get("Range"); got != "bytes=10-20" {
				t.Errorf("Range = %q, want bytes=10-20", got)
			}
			return httpmock.NewStringResponse(206, "partial"), nil
		})

	rc, err := c.Read(context.Background(), "work", wsGUID, itemGUID, "Files/a.csv", 10, 20)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	defer rc.Close()
	b, _ := io.ReadAll(rc)
	if string(b) != "partial" {
		t.Errorf("body = %q", b)
	}
}

func TestCreateDirectory(t *testing.T) {
	c := newTestClient(t)
	called := false
	httpmock.RegisterResponder("PUT", "=~^"+testBase+"/"+wsGUID+"/"+itemGUID+`/Files/new\?.*$`,
		func(req *http.Request) (*http.Response, error) {
			called = true
			if req.URL.Query().Get("resource") != "directory" {
				t.Errorf("resource = %q, want directory", req.URL.Query().Get("resource"))
			}
			return httpmock.NewStringResponse(201, ""), nil
		})
	if err := c.CreateDirectory(context.Background(), "work", wsGUID, itemGUID, "Files/new"); err != nil {
		t.Fatalf("CreateDirectory: %v", err)
	}
	if !called {
		t.Error("PUT not called")
	}
}

func TestDelete_Recursive(t *testing.T) {
	c := newTestClient(t)
	called := false
	httpmock.RegisterResponder("DELETE", "=~^"+testBase+"/"+wsGUID+"/"+itemGUID+`/Files/old(\?.*)?$`,
		func(req *http.Request) (*http.Response, error) {
			called = true
			if req.URL.Query().Get("recursive") != "true" {
				t.Errorf("recursive = %q, want true", req.URL.Query().Get("recursive"))
			}
			return httpmock.NewStringResponse(200, ""), nil
		})
	if err := c.Delete(context.Background(), "work", wsGUID, itemGUID, "Files/old", true); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if !called {
		t.Error("DELETE not called")
	}
}

func TestDelete_NonRecursiveConflict(t *testing.T) {
	c := newTestClient(t)
	httpmock.RegisterResponder("DELETE", "=~^"+testBase+"/"+wsGUID+"/"+itemGUID+`/Files/old(\?.*)?$`,
		httpmock.NewStringResponder(409, "conflict"))
	err := c.Delete(context.Background(), "work", wsGUID, itemGUID, "Files/old", false)
	if !errors.Is(err, api.ErrConflict) {
		t.Fatalf("want ErrConflict, got %v", err)
	}
}

// TestWrite_ChunkedUpload_10MB is the load-bearing test from the spec:
// a 10 MiB body must produce exactly one create (PUT ?resource=file),
// three append PATCHes (4 MiB, 4 MiB, 2 MiB), and one flush PATCH.
// Total = 5 requests.
func TestWrite_ChunkedUpload_10MB(t *testing.T) {
	c := newTestClient(t)

	const total = 10 * 1024 * 1024
	body := bytes.Repeat([]byte("x"), total)

	type rec struct {
		method   string
		resource string
		action   string
		position string
		bodyLen  int
	}
	var (
		mu      sync.Mutex
		records []rec
	)

	readBody := func(req *http.Request) []byte {
		if req.Body == nil {
			return nil
		}
		b, _ := io.ReadAll(req.Body)
		return b
	}

	httpmock.RegisterResponder("PUT", "=~^"+testBase+"/"+wsGUID+"/"+itemGUID+`/Files/big\.bin\?.*$`,
		func(req *http.Request) (*http.Response, error) {
			mu.Lock()
			defer mu.Unlock()
			b := readBody(req)
			records = append(records, rec{
				method:   "PUT",
				resource: req.URL.Query().Get("resource"),
				action:   req.URL.Query().Get("action"),
				position: req.URL.Query().Get("position"),
				bodyLen:  len(b),
			})
			return httpmock.NewStringResponse(201, ""), nil
		})

	httpmock.RegisterResponder("PATCH", "=~^"+testBase+"/"+wsGUID+"/"+itemGUID+`/Files/big\.bin\?.*$`,
		func(req *http.Request) (*http.Response, error) {
			mu.Lock()
			defer mu.Unlock()
			b := readBody(req)
			records = append(records, rec{
				method:   "PATCH",
				resource: req.URL.Query().Get("resource"),
				action:   req.URL.Query().Get("action"),
				position: req.URL.Query().Get("position"),
				bodyLen:  len(b),
			})
			return httpmock.NewStringResponse(202, ""), nil
		})

	err := c.Write(context.Background(), "work", wsGUID, itemGUID, "Files/big.bin",
		bytes.NewReader(body), int64(total))
	if err != nil {
		t.Fatalf("Write: %v", err)
	}

	if len(records) != 5 {
		t.Fatalf("got %d HTTP calls, want 5 (create + 3 append + flush). records: %+v",
			len(records), records)
	}

	// Sequence check.
	expected := []rec{
		{method: "PUT", resource: "file", action: "", position: "", bodyLen: 0},
		{method: "PATCH", resource: "", action: "append", position: "0", bodyLen: 4 * 1024 * 1024},
		{method: "PATCH", resource: "", action: "append", position: fmt.Sprintf("%d", 4*1024*1024), bodyLen: 4 * 1024 * 1024},
		{method: "PATCH", resource: "", action: "append", position: fmt.Sprintf("%d", 8*1024*1024), bodyLen: 2 * 1024 * 1024},
		{method: "PATCH", resource: "", action: "flush", position: fmt.Sprintf("%d", total), bodyLen: 0},
	}
	for i, want := range expected {
		got := records[i]
		if got.method != want.method || got.resource != want.resource || got.action != want.action {
			t.Errorf("step %d: got %+v, want %+v", i, got, want)
		}
		if got.position != want.position {
			t.Errorf("step %d position: got %q, want %q", i, got.position, want.position)
		}
		if got.bodyLen != want.bodyLen {
			t.Errorf("step %d bodyLen: got %d, want %d", i, got.bodyLen, want.bodyLen)
		}
	}
}

func TestWrite_EmptyFile(t *testing.T) {
	c := newTestClient(t)

	var calls []string
	httpmock.RegisterResponder("PUT", "=~^"+testBase+`.*$`,
		func(req *http.Request) (*http.Response, error) {
			calls = append(calls, "PUT?"+req.URL.RawQuery)
			return httpmock.NewStringResponse(201, ""), nil
		})
	httpmock.RegisterResponder("PATCH", "=~^"+testBase+`.*$`,
		func(req *http.Request) (*http.Response, error) {
			calls = append(calls, "PATCH?"+req.URL.RawQuery)
			return httpmock.NewStringResponse(202, ""), nil
		})

	if err := c.Write(context.Background(), "work", wsGUID, itemGUID, "Files/empty",
		strings.NewReader(""), 0); err != nil {
		t.Fatalf("Write: %v", err)
	}
	// create + flush only (no append calls for zero bytes).
	if len(calls) != 2 {
		t.Errorf("calls = %v, want 2 (create + flush)", calls)
	}
}

func TestWrite_ShortRead(t *testing.T) {
	c := newTestClient(t)

	httpmock.RegisterResponder("PUT", "=~^"+testBase+`.*$`,
		httpmock.NewStringResponder(201, ""))
	httpmock.RegisterResponder("PATCH", "=~^"+testBase+`.*$`,
		httpmock.NewStringResponder(202, ""))

	// Claim 100 bytes but provide only 10.
	err := c.Write(context.Background(), "work", wsGUID, itemGUID, "Files/short",
		strings.NewReader("0123456789"), 100)
	if !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("want ErrUnexpectedEOF, got %v", err)
	}
}

func TestListPath_401(t *testing.T) {
	c := newTestClient(t)
	httpmock.RegisterResponder("GET", "=~^"+testBase+"/"+wsGUID+`\?.*$`,
		httpmock.NewStringResponder(401, ""))
	_, err := c.ListPath(context.Background(), "work", wsGUID, itemGUID, "", false)
	if !errors.Is(err, api.ErrUnauthorized) {
		t.Fatalf("want ErrUnauthorized, got %v", err)
	}
}

func TestRead_429RetriedThenSucceeds(t *testing.T) {
	c := newTestClient(t)
	var calls int
	httpmock.RegisterResponder("GET", testBase+"/"+wsGUID+"/"+itemGUID+"/Files/a.csv",
		func(req *http.Request) (*http.Response, error) {
			calls++
			if calls == 1 {
				r := httpmock.NewStringResponse(429, "")
				r.Header.Set("Retry-After", "0")
				return r, nil
			}
			return httpmock.NewStringResponse(200, "hello"), nil
		})
	rc, err := c.Read(context.Background(), "work", wsGUID, itemGUID, "Files/a.csv", 0, -1)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	defer rc.Close()
	b, _ := io.ReadAll(rc)
	if string(b) != "hello" || calls != 2 {
		t.Errorf("body=%q calls=%d", b, calls)
	}
}

func TestValidationErrors(t *testing.T) {
	c := newTestClient(t)
	ctx := context.Background()

	if _, err := c.ListPath(ctx, "work", "", itemGUID, "", false); err == nil {
		t.Error("missing workspaceGUID should error")
	}
	if _, err := c.GetProperties(ctx, "work", wsGUID, "", "x"); err == nil {
		t.Error("missing itemGUID should error")
	}
	if err := c.Write(ctx, "work", wsGUID, itemGUID, "", nil, 0); err == nil {
		t.Error("empty path should error")
	}
	if err := c.CreateDirectory(ctx, "work", wsGUID, itemGUID, ""); err == nil {
		t.Error("empty path should error")
	}
	if err := c.Delete(ctx, "work", wsGUID, itemGUID, "", false); err == nil {
		t.Error("empty path should error")
	}
}
