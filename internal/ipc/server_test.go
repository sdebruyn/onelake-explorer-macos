package ipc

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// quietLogger returns a slog.Logger whose output is discarded. Used in
// tests so the race detector does not have to consider every concurrent
// log call from the shared default handler.
func quietLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
}

// shortSocketPath returns a path short enough to fit in macOS's sun_path
// limit (104 bytes). t.TempDir() under /var/folders/.../T/<TestName>/...
// often exceeds the limit, especially with -race and -parallel, so we
// build our own path under /tmp instead.
func shortSocketPath(t *testing.T) string {
	t.Helper()
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}
	dir := filepath.Join(os.TempDir(), "ofe-ipc-"+hex.EncodeToString(b[:]))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return filepath.Join(dir, "s")
}

// startTestServer spins up a Server on a socket inside t.TempDir() and
// returns the resolved socket path. Cleanup is registered via t.Cleanup.
func startTestServer(t *testing.T, register func(*Server)) (string, *Server) {
	t.Helper()

	sockPath := shortSocketPath(t)
	srv := NewServer(quietLogger())
	if register != nil {
		register(srv)
	}

	listenErr := make(chan error, 1)
	go func() {
		listenErr <- srv.Listen(context.Background(), sockPath)
	}()

	// Block until the listener is bound so Dial doesn't race against
	// listener setup.
	select {
	case <-srv.Ready():
	case <-time.After(2 * time.Second):
		t.Fatalf("server did not bind socket in time")
	}
	if srv.SocketPath() == "" {
		t.Fatalf("server marked ready but SocketPath is empty")
	}

	t.Cleanup(func() {
		// Close first so the accept loop unblocks and listen() returns,
		// then wait for the listen() goroutine to actually exit. Doing
		// both ensures no concurrent access to the Server outlives this
		// cleanup.
		_ = srv.Close()
		select {
		case <-listenErr:
		case <-time.After(2 * time.Second):
			t.Errorf("server did not stop on close")
		}
	})

	return sockPath, srv
}

func TestServerRoundTrip(t *testing.T) {
	t.Parallel()

	type echoIn struct {
		Msg string `json:"msg"`
	}
	type echoOut struct {
		Echo string `json:"echo"`
	}
	path, _ := startTestServer(t, func(s *Server) {
		s.Register("echo", func(_ context.Context, params json.RawMessage) (any, error) {
			var in echoIn
			if err := json.Unmarshal(params, &in); err != nil {
				return nil, err
			}
			return echoOut{Echo: in.Msg}, nil
		})
	})

	c, err := Dial(path)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer func() { _ = c.Close() }()

	var got echoOut
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := c.Call(ctx, "echo", echoIn{Msg: "hello"}, &got); err != nil {
		t.Fatalf("Call: %v", err)
	}
	if got.Echo != "hello" {
		t.Fatalf("got echo %q, want hello", got.Echo)
	}
}

func TestServerMethodNotFound(t *testing.T) {
	t.Parallel()

	path, _ := startTestServer(t, nil)
	c, err := Dial(path)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer func() { _ = c.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err = c.Call(ctx, "missing", nil, nil)
	var eo *ErrorObject
	if !errors.As(err, &eo) {
		t.Fatalf("expected *ErrorObject, got %T (%v)", err, err)
	}
	if eo.Code != CodeMethodNotFound {
		t.Fatalf("code: got %d want %d", eo.Code, CodeMethodNotFound)
	}
}

func TestServerHandlerError(t *testing.T) {
	t.Parallel()

	path, _ := startTestServer(t, func(s *Server) {
		s.Register("fail", func(_ context.Context, _ json.RawMessage) (any, error) {
			return nil, errors.New("nope")
		})
	})
	c, err := Dial(path)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer func() { _ = c.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err = c.Call(ctx, "fail", nil, nil)
	var eo *ErrorObject
	if !errors.As(err, &eo) {
		t.Fatalf("expected *ErrorObject, got %T (%v)", err, err)
	}
	if eo.Code != CodeHandlerError || eo.Message != "nope" {
		t.Fatalf("got %+v, want CodeHandlerError 'nope'", eo)
	}
}

func TestServerHandlerPanicRecovered(t *testing.T) {
	t.Parallel()

	path, _ := startTestServer(t, func(s *Server) {
		s.Register("boom", func(_ context.Context, _ json.RawMessage) (any, error) {
			panic("oops")
		})
	})
	c, err := Dial(path)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer func() { _ = c.Close() }()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err = c.Call(ctx, "boom", nil, nil)
	var eo *ErrorObject
	if !errors.As(err, &eo) {
		t.Fatalf("expected *ErrorObject, got %T (%v)", err, err)
	}
	if eo.Code != CodeHandlerError {
		t.Fatalf("code: got %d want CodeHandlerError", eo.Code)
	}

	// Connection should still be alive — issue another call to prove it.
	path2, _ := startTestServer(t, func(s *Server) {
		s.Register("ping", func(_ context.Context, _ json.RawMessage) (any, error) {
			return "pong", nil
		})
	})
	c2, err := Dial(path2)
	if err != nil {
		t.Fatalf("Dial second server: %v", err)
	}
	defer func() { _ = c2.Close() }()
	var out string
	if err := c2.Call(ctx, "ping", nil, &out); err != nil {
		t.Fatalf("ping: %v", err)
	}
	if out != "pong" {
		t.Fatalf("ping result: got %q want pong", out)
	}
}

func TestServerConcurrentClients(t *testing.T) {
	t.Parallel()

	path, _ := startTestServer(t, func(s *Server) {
		s.Register("double", func(_ context.Context, params json.RawMessage) (any, error) {
			var n int
			if err := json.Unmarshal(params, &n); err != nil {
				return nil, err
			}
			return n * 2, nil
		})
	})

	const N = 20
	var wg sync.WaitGroup
	errs := make(chan error, N)
	for i := 0; i < N; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			c, err := Dial(path)
			if err != nil {
				errs <- err
				return
			}
			defer func() { _ = c.Close() }()
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			var got int
			if err := c.Call(ctx, "double", i, &got); err != nil {
				errs <- err
				return
			}
			if got != i*2 {
				errs <- errors.New("wrong result")
			}
		}(i)
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Errorf("concurrent client: %v", err)
	}
}

func TestServerListenTwiceFails(t *testing.T) {
	t.Parallel()

	path := shortSocketPath(t)
	path2 := shortSocketPath(t)
	srv := NewServer(quietLogger())
	go func() { _ = srv.Listen(context.Background(), path) }()

	select {
	case <-srv.Ready():
	case <-time.After(2 * time.Second):
		t.Fatalf("first Listen never bound socket")
	}
	defer func() { _ = srv.Close() }()

	errCh := make(chan error, 1)
	go func() { errCh <- srv.Listen(context.Background(), path2) }()
	select {
	case err := <-errCh:
		if err == nil {
			t.Fatalf("expected second Listen to fail, got nil")
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("second Listen blocked instead of returning an already-started error")
	}
}

func TestClientCallOnClosed(t *testing.T) {
	t.Parallel()

	path, _ := startTestServer(t, nil)
	c, err := Dial(path)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	if err := c.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := c.Call(ctx, "anything", nil, nil); err == nil {
		t.Fatalf("expected error on Call after Close")
	}
}
