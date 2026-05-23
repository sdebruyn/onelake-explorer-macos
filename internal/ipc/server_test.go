package ipc

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
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

// TestListen_ReplacesStaleFile verifies that a pre-existing non-socket
// file at the bind path (the typical signature of a crashed daemon
// leaving a stale Unix socket behind) is unlinked and replaced. We use
// a regular file rather than a real stale socket because a regular file
// is guaranteed to fail the dial probe with a non-timeout error, which
// exercises the unlink-and-listen branch deterministically.
func TestListen_ReplacesStaleFile(t *testing.T) {
	t.Parallel()

	sockPath := shortSocketPath(t)
	if err := os.WriteFile(sockPath, []byte("stale"), 0o600); err != nil {
		t.Fatalf("pre-create stale file: %v", err)
	}

	srv := NewServer(quietLogger())
	listenErr := make(chan error, 1)
	go func() { listenErr <- srv.Listen(context.Background(), sockPath) }()

	select {
	case <-srv.Ready():
	case <-time.After(2 * time.Second):
		t.Fatalf("server did not bind socket in time")
	}
	if srv.SocketPath() == "" {
		t.Fatalf("server marked ready but SocketPath is empty: stale file was not replaced")
	}
	t.Cleanup(func() {
		_ = srv.Close()
		select {
		case <-listenErr:
		case <-time.After(2 * time.Second):
			t.Errorf("server did not stop on close")
		}
	})

	// Round-trip a call to prove the listener actually answers.
	srv.Register("ping", func(_ context.Context, _ json.RawMessage) (any, error) {
		return "pong", nil
	})
	c, err := Dial(sockPath)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer func() { _ = c.Close() }()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var out string
	if err := c.Call(ctx, "ping", nil, &out); err != nil {
		t.Fatalf("ping: %v", err)
	}
	if out != "pong" {
		t.Fatalf("ping result: got %q want pong", out)
	}
}

// TestListen_RefusesLivePeer verifies that a second Listen against a
// socket already serviced by a healthy peer fails with ErrPeerListening
// instead of silently unlinking the live socket (which would split-brain
// two daemons over shared on-disk state).
func TestListen_RefusesLivePeer(t *testing.T) {
	t.Parallel()

	sockPath := shortSocketPath(t)

	// Spin up a vanilla Unix listener that accepts and immediately
	// closes connections — enough to make Dial succeed, which is all
	// the probe checks.
	peer, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("pre-listen: %v", err)
	}
	defer func() { _ = peer.Close() }()

	peerDone := make(chan struct{})
	go func() {
		defer close(peerDone)
		for {
			c, err := peer.Accept()
			if err != nil {
				return
			}
			_ = c.Close()
		}
	}()

	srv := NewServer(quietLogger())
	bindErr := make(chan error, 1)
	go func() { bindErr <- srv.Listen(context.Background(), sockPath) }()

	select {
	case err := <-bindErr:
		if err == nil {
			t.Fatalf("expected Listen to fail with ErrPeerListening, got nil")
		}
		if !errors.Is(err, ErrPeerListening) {
			t.Fatalf("expected ErrPeerListening, got %v", err)
		}
		if !strings.Contains(err.Error(), "already") {
			t.Errorf("error message should mention 'already': %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("Listen blocked instead of refusing live peer")
	}

	// The bind failure must NOT have removed the live peer's socket
	// file: dial it again and confirm the peer still answers.
	c, err := net.DialTimeout("unix", sockPath, 500*time.Millisecond)
	if err != nil {
		t.Fatalf("live peer's socket disappeared after refused bind: %v", err)
	}
	_ = c.Close()

	// Ready must still be signalled so the caller's wait does not hang.
	select {
	case <-srv.Ready():
	case <-time.After(time.Second):
		t.Errorf("Ready channel was not closed on failed bind")
	}
	if srv.SocketPath() != "" {
		t.Errorf("SocketPath populated after failed bind: %q", srv.SocketPath())
	}

	_ = peer.Close()
	<-peerDone
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
