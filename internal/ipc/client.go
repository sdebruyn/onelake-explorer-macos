package ipc

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"
)

// Client is a minimal JSON-RPC 2.0 client over a single Unix-domain
// socket connection. It is safe for concurrent use, but every call is
// serialised under a per-client mutex because the framing layer assumes
// requests and responses pair up one-to-one over the wire.
//
// Construct with [Dial]. Close the underlying connection with
// [Client.Close].
type Client struct {
	mu   sync.Mutex
	conn net.Conn
}

// Dial connects to the daemon's Unix domain socket at path and returns a
// ready-to-use [Client]. The caller is responsible for invoking
// [Client.Close] when done.
//
// Dial has no built-in timeout; it blocks for as long as the kernel
// will wait on a Unix-socket connect, which on macOS is effectively
// instant for a live socket and immediate-fail for a missing one. Use
// [DialContext] when you need to bound the connect by your own
// deadline (for example, when an unresponsive daemon must not stall a
// short-lived CLI command).
func Dial(path string) (*Client, error) {
	return DialContext(context.Background(), path)
}

// DialContext is like [Dial] but honours ctx's deadline for the
// underlying socket connect. A cancelled or expired ctx returns
// promptly with the ctx error wrapped.
//
// The returned client does NOT capture ctx; per-call cancellation
// should be passed through [Client.Call] via its own ctx argument.
func DialContext(ctx context.Context, path string) (*Client, error) {
	if path == "" {
		return nil, errors.New("ipc.Dial: socket path is required")
	}
	var d net.Dialer
	conn, err := d.DialContext(ctx, "unix", path)
	if err != nil {
		return nil, fmt.Errorf("ipc.Dial %q: %w", path, err)
	}
	return &Client{conn: conn}, nil
}

// Close closes the underlying socket connection. It is safe to call
// multiple times.
func (c *Client) Close() error {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn == nil {
		return nil
	}
	err := c.conn.Close()
	c.conn = nil
	return err
}

// Call sends a JSON-RPC request and decodes the response into out. params
// may be nil; out may be nil if the caller doesn't care about the
// result. On any IO or framing error the underlying connection is torn
// down so the caller cannot accidentally reuse a desynchronised socket.
//
// If ctx has a deadline, it is mapped onto a socket-level read/write
// deadline before the request is sent. Cancellation after the request is
// in flight unblocks the read by closing the connection, which means
// subsequent Calls will fail.
func (c *Client) Call(ctx context.Context, method string, params any, out any) error {
	if method == "" {
		return errors.New("ipc.Client.Call: method is required")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn == nil {
		return errors.New("ipc.Client.Call: client closed")
	}

	var paramsRaw json.RawMessage
	if params != nil {
		encoded, err := json.Marshal(params)
		if err != nil {
			return fmt.Errorf("ipc: encode params: %w", err)
		}
		paramsRaw = encoded
	}

	id := newRequestID()
	req := &Request{
		JSONRPC: JSONRPCVersion,
		Method:  method,
		Params:  paramsRaw,
		ID:      id,
	}
	data, err := EncodeRequest(req)
	if err != nil {
		return fmt.Errorf("ipc: encode request: %w", err)
	}

	// Snapshot the connection so the cancel watcher can act on a stable
	// reference without racing a concurrent Close that would nil out
	// c.conn.
	conn := c.conn

	if deadline, ok := ctx.Deadline(); ok {
		if err := conn.SetDeadline(deadline); err != nil {
			return fmt.Errorf("ipc: set deadline: %w", err)
		}
	} else {
		// Clear any deadline left over from a previous Call.
		_ = conn.SetDeadline(time.Time{})
	}

	// Cancellation while we are blocked on a read forces the next IO to
	// fail immediately by setting an already-past deadline. The done
	// channel coordinates the watcher goroutine's lifecycle so it does
	// not leak past Call.
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.SetDeadline(time.Unix(1, 0))
		case <-done:
		}
	}()

	if err := WriteFrame(conn, data); err != nil {
		c.teardownLocked()
		return fmt.Errorf("ipc: write request: %w", err)
	}

	frame, err := ReadFrame(conn)
	if err != nil {
		c.teardownLocked()
		return fmt.Errorf("ipc: read response: %w", err)
	}
	resp, err := DecodeResponse(frame)
	if err != nil {
		c.teardownLocked()
		return fmt.Errorf("ipc: decode response: %w", err)
	}
	if resp.Error != nil {
		return resp.Error
	}
	if out == nil || len(resp.Result) == 0 {
		return nil
	}
	if err := json.Unmarshal(resp.Result, out); err != nil {
		return fmt.Errorf("ipc: decode result: %w", err)
	}
	return nil
}

// teardownLocked closes the connection and nils it out. Callers must
// already hold c.mu.
func (c *Client) teardownLocked() {
	if c.conn == nil {
		return
	}
	_ = c.conn.Close()
	c.conn = nil
}

// newRequestID returns a fresh JSON-encoded ID. We use 8 random hex
// bytes which is enough entropy to make accidental collision within one
// connection effectively impossible.
func newRequestID() json.RawMessage {
	var buf [8]byte
	_, _ = rand.Read(buf[:])
	// Wrap in JSON string quotes so it round-trips through json.RawMessage.
	return json.RawMessage(`"` + hex.EncodeToString(buf[:]) + `"`)
}
