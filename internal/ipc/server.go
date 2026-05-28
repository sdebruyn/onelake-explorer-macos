package ipc

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// peerProbeTimeout caps how long the bind path waits for a Dial against
// an existing socket file to either connect or be refused. 250 ms is
// generous on a loopback Unix socket: a healthy peer returns within
// micros, and stale-file paths fail with ECONNREFUSED essentially
// instantly. The timeout exists so a half-dead peer (process alive but
// not accepting) does not freeze startup forever.
const peerProbeTimeout = 250 * time.Millisecond

// ErrPeerListening is returned by [Server.Listen] when the configured
// socket path already has a live peer accepting connections. The caller
// should NOT retry by unlinking the file: that would split-brain two
// daemons against shared on-disk state. Surface the error and exit.
var ErrPeerListening = errors.New("ipc: another listener is already serving the socket")

// Handler is the signature every registered IPC method exposes. ctx is
// cancelled when the server shuts down or the client disconnects, and
// params carries the raw JSON payload from [Request.Params]. The return
// value, if non-nil, is JSON-encoded into [Response.Result]; a non-nil
// error becomes an [ErrorObject] with [CodeHandlerError].
type Handler func(ctx context.Context, params json.RawMessage) (any, error)

// Server is the daemon-side IPC endpoint. It owns a Unix-domain-socket
// listener and dispatches incoming Requests to handlers registered via
// [Server.Register].
//
// Construct with [NewServer]. The zero value is not usable.
type Server struct {
	logger *slog.Logger

	handlersMu sync.RWMutex
	handlers   map[string]Handler

	// stateMu guards the listener/socketPath/listening/closed transitions
	// below. It is taken only for short, non-blocking critical sections;
	// hot-path request handling does not need it.
	stateMu    sync.Mutex
	listener   net.Listener
	socketPath string
	listening  bool
	closed     bool

	ready    chan struct{} // closed once listen() has finished its bind attempt
	closing  chan struct{} // closed by Close to signal shutdown
	acceptWG sync.WaitGroup
	connWG   sync.WaitGroup
}

// NewServer returns a Server with no registered handlers. logger may be
// nil; when nil [slog.Default] is used.
func NewServer(logger *slog.Logger) *Server {
	if logger == nil {
		logger = slog.Default()
	}
	return &Server{
		logger:   logger.With(slog.String("component", "ipc")),
		handlers: make(map[string]Handler),
		closing:  make(chan struct{}),
		ready:    make(chan struct{}),
	}
}

// Register binds handler to method. Calling Register twice for the same
// method overwrites the previous handler; this is intentional so tests
// can swap stubs.
func (s *Server) Register(method string, handler Handler) {
	if handler == nil {
		panic("ipc.Server.Register: nil handler")
	}
	s.handlersMu.Lock()
	defer s.handlersMu.Unlock()
	s.handlers[method] = handler
}

// Listen binds the server to a Unix domain socket at path, then accepts
// connections until ctx is cancelled or [Server.Close] is called. The
// socket file is created with mode 0600 (owner-only).
//
// If a file already exists at path, Listen probes it with a short Dial
// (capped at [peerProbeTimeout]). If the Dial succeeds, another daemon
// is already serving the socket and Listen refuses to start, returning
// [ErrPeerListening] — unlinking the live socket would orphan the
// running peer and create split-brain access to shared on-disk state.
// If the Dial fails (ECONNREFUSED, timeout, or any other error), the
// file is considered stale and is unlinked before binding.
//
// Listen returns when the listener stops accepting; in-flight handlers
// continue running and Listen does not wait for them. Use [Server.Close]
// for an explicit graceful shutdown that drains workers.
//
// Calling Listen a second time returns an error immediately; the server
// is single-use.
func (s *Server) Listen(ctx context.Context, path string) error {
	s.stateMu.Lock()
	if s.listening {
		s.stateMu.Unlock()
		return errors.New("ipc.Server.Listen: already started")
	}
	if s.closed {
		s.stateMu.Unlock()
		return errors.New("ipc.Server.Listen: server is closed")
	}
	s.listening = true
	s.stateMu.Unlock()

	return s.listen(ctx, path)
}

func (s *Server) listen(ctx context.Context, path string) error {
	// We must unblock Ready() on every exit path — bind success AND
	// bind failure — so callers blocked on Ready() don't hang. A
	// deferred markReady at the top would cover all paths in one
	// line, but it would only fire when listen returns, which on the
	// happy path is at shutdown. So instead we mark ready explicitly:
	// once on the bind-success path below, and once via failedBind on
	// each early-return error path. markReady itself is idempotent.
	failedBind := func(err error) error {
		s.markReady()
		return err
	}

	if path == "" {
		return failedBind(errors.New("ipc.Server.Listen: socket path is required"))
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return failedBind(fmt.Errorf("ipc: create socket parent dir: %w", err))
	}
	// If a file (socket or otherwise) already exists at path, decide
	// whether it is a stale leftover that we can safely unlink or a
	// live peer that we must not stomp on. reclaimSocketPath handles
	// both: a successful Dial means a peer is accepting and we refuse
	// to start; any other outcome (including "not a socket") lets us
	// unlink and continue.
	if err := s.reclaimSocketPath(path); err != nil {
		return failedBind(err)
	}

	ln, err := net.Listen("unix", path)
	if err != nil {
		return failedBind(fmt.Errorf("ipc: listen unix %q: %w", path, err))
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = ln.Close()
		return failedBind(fmt.Errorf("ipc: chmod socket: %w", err))
	}

	s.stateMu.Lock()
	if s.closed {
		s.stateMu.Unlock()
		_ = ln.Close()
		return failedBind(errors.New("ipc.Server.Listen: server closed during bind"))
	}
	s.listener = ln
	s.socketPath = path
	// Bump acceptWG while still holding stateMu so any subsequent Close
	// either observes the bumped counter (Wait waits) or sees s.closed
	// already set and bails on bind. This keeps WaitGroup semantics
	// clean: Add always happens-before Wait.
	s.acceptWG.Add(1)
	s.stateMu.Unlock()

	// Bind succeeded; unblock Ready() so callers don't have to wait
	// for acceptLoop to return (which only happens at shutdown).
	s.markReady()
	s.logger.Info("ipc server listening", slog.String("socket", path))

	// Tie listener shutdown to ctx cancellation so the daemon can stop
	// us by cancelling its root context.
	go func() {
		select {
		case <-ctx.Done():
		case <-s.closing:
		}
		_ = ln.Close()
	}()

	s.acceptLoop(ctx, ln)
	s.acceptWG.Done()
	return nil
}

// reclaimSocketPath inspects an existing file at path and either
// unlinks it (stale) or returns [ErrPeerListening] (live). It returns
// nil if no file exists at path; in that case the bind path falls
// straight through to net.Listen.
//
// The "live peer" check is a Dial with [peerProbeTimeout]: a healthy
// listener accepts almost immediately; anything else (ECONNREFUSED on
// a leftover socket file, ENOENT race, file-but-not-a-socket, timeout)
// means we can take the path over.
//
// There is a benign race between the dial-probe and the unlink: a peer
// could bind the path in that window. This is harmless because the
// subsequent net.Listen will then fail with EADDRINUSE and the caller
// surfaces that error normally.
func (s *Server) reclaimSocketPath(path string) error {
	// Lstat (not Stat) so we inspect the path itself, never a symlink
	// target — we must never be tricked into unlinking something the
	// symlink points at.
	fi, err := os.Lstat(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		// Surface other lstat errors (e.g. permission denied on the
		// parent dir) so a misconfiguration is visible instead of
		// silently retried.
		return fmt.Errorf("ipc: lstat socket path: %w", err)
	}
	// A genuine stale OFEM socket is a socket file we own. Refuse to
	// reclaim anything else: a symlink (could redirect the unlink) or a
	// file owned by another uid. The socket lives in the owner-only App
	// Group container, so this is defense in depth against a local
	// pre-creation/symlink-swap attempt.
	if fi.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("ipc: refusing to reclaim symlink at socket path %q", path)
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && int(st.Uid) != os.Geteuid() {
		return fmt.Errorf("ipc: refusing to reclaim socket path %q owned by uid %d", path, st.Uid)
	}

	conn, dialErr := net.DialTimeout("unix", path, peerProbeTimeout)
	if dialErr == nil {
		_ = conn.Close()
		return fmt.Errorf("%w: %s", ErrPeerListening, path)
	}

	// Dial failed: file is either a stale socket (typical case after
	// a daemon crash → ECONNREFUSED) or not a socket at all
	// (regular file the user pre-created). Either way, unlink it.
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("ipc: remove stale socket: %w", err)
	}
	return nil
}

// markReady closes s.ready exactly once. Safe to call from anywhere.
func (s *Server) markReady() {
	s.stateMu.Lock()
	defer s.stateMu.Unlock()
	select {
	case <-s.ready:
	default:
		close(s.ready)
	}
}

func (s *Server) acceptLoop(ctx context.Context, ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			// A closed listener is the normal shutdown path; do not
			// log it at error level.
			if errors.Is(err, net.ErrClosed) {
				return
			}
			// Transient accept errors (rare on a Unix socket) are
			// worth a log line but should not kill the loop.
			s.logger.Warn("ipc accept error", slog.Any("err", err))
			continue
		}
		s.connWG.Add(1)
		go func(c net.Conn) {
			defer s.connWG.Done()
			s.serveConn(ctx, c)
		}(conn)
	}
}

// Close stops accepting new connections, signals in-flight handlers via
// their context, and waits for them to return. It also removes the
// socket file from disk so a fresh start does not have to clean up after
// us.
//
// Close is safe to call multiple times and from any goroutine.
func (s *Server) Close() error {
	s.stateMu.Lock()
	if s.closed {
		s.stateMu.Unlock()
		s.acceptWG.Wait()
		s.connWG.Wait()
		return nil
	}
	s.closed = true
	ln := s.listener
	path := s.socketPath
	s.stateMu.Unlock()

	close(s.closing)
	if ln != nil {
		_ = ln.Close()
	}
	// Wait for the accept loop to exit before waiting on per-connection
	// workers; this preserves WaitGroup semantics (no Add concurrent
	// with Wait when the counter is zero).
	s.acceptWG.Wait()
	s.connWG.Wait()
	if path != "" {
		// Best-effort removal; a missing file is fine.
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			s.logger.Warn("ipc: remove socket on close", slog.Any("err", err))
		}
	}
	return nil
}

// SocketPath returns the path the server is (or was) bound to. Empty
// before [Server.Listen] succeeds.
func (s *Server) SocketPath() string {
	s.stateMu.Lock()
	defer s.stateMu.Unlock()
	return s.socketPath
}

// Ready returns a channel that is closed once [Server.Listen] has
// finished its bind attempt. Callers should check [Server.SocketPath] to
// confirm the bind actually succeeded.
func (s *Server) Ready() <-chan struct{} { return s.ready }

// serveConn runs one accepted connection: read a frame, dispatch, write
// a response, repeat until the peer closes or an unrecoverable error
// occurs. Per-request errors do not tear the connection down; only IO
// errors or oversized frames do.
func (s *Server) serveConn(parent context.Context, conn net.Conn) {
	defer func() { _ = conn.Close() }()
	connCtx, cancel := context.WithCancel(parent)
	defer cancel()

	for {
		frame, err := ReadFrame(conn)
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) {
				s.logger.Debug("ipc connection ended", slog.Any("err", err))
			}
			return
		}

		req, decErr := DecodeRequest(frame)
		if decErr != nil {
			s.writeError(conn, nil, CodeParseError, decErr.Error())
			continue
		}
		if req.JSONRPC != "" && req.JSONRPC != JSONRPCVersion {
			s.writeError(conn, req.ID, CodeInvalidRequest, "unsupported jsonrpc version")
			continue
		}
		if req.Method == "" {
			s.writeError(conn, req.ID, CodeInvalidRequest, "missing method")
			continue
		}

		s.handlersMu.RLock()
		handler, ok := s.handlers[req.Method]
		s.handlersMu.RUnlock()
		if !ok {
			s.writeError(conn, req.ID, CodeMethodNotFound, "method not found: "+req.Method)
			continue
		}

		result, hErr := s.invoke(connCtx, handler, req.Params)
		if hErr != nil {
			s.writeError(conn, req.ID, CodeHandlerError, hErr.Error())
			continue
		}
		s.writeResult(conn, req.ID, result)
	}
}

// invoke runs handler under a recover so a buggy handler can't take the
// entire daemon down. The recovered value becomes a regular error so the
// caller's logging path handles it uniformly.
func (s *Server) invoke(ctx context.Context, handler Handler, params json.RawMessage) (result any, err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("handler panic: %v", r)
		}
	}()
	return handler(ctx, params)
}

func (s *Server) writeResult(w io.Writer, id json.RawMessage, result any) {
	var raw json.RawMessage
	if result != nil {
		encoded, err := json.Marshal(result)
		if err != nil {
			s.writeError(w, id, CodeInternalError, "encode result: "+err.Error())
			return
		}
		raw = encoded
	}
	resp := &Response{JSONRPC: JSONRPCVersion, Result: raw, ID: id}
	data, err := EncodeResponse(resp)
	if err != nil {
		s.logger.Error("ipc: encode response", slog.Any("err", err))
		return
	}
	if err := WriteFrame(w, data); err != nil {
		s.logger.Debug("ipc: write response", slog.Any("err", err))
	}
}

func (s *Server) writeError(w io.Writer, id json.RawMessage, code int, msg string) {
	resp := &Response{
		JSONRPC: JSONRPCVersion,
		Error:   &ErrorObject{Code: code, Message: msg},
		ID:      id,
	}
	data, err := EncodeResponse(resp)
	if err != nil {
		s.logger.Error("ipc: encode error response", slog.Any("err", err))
		return
	}
	if err := WriteFrame(w, data); err != nil {
		s.logger.Debug("ipc: write error response", slog.Any("err", err))
	}
}
