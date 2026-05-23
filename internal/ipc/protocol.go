package ipc

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// JSONRPCVersion is the protocol marker required on every Request and
// Response per the JSON-RPC 2.0 specification.
const JSONRPCVersion = "2.0"

// MaxFrameSize is the hard upper bound on a single JSON-RPC frame
// payload, in bytes. Anything larger is rejected to keep a buggy or
// hostile peer from exhausting daemon memory. 1 MiB is well over the
// largest realistic request (an account.add with a serialized MSAL
// cache is on the order of tens of KiB).
const MaxFrameSize = 1 << 20

// ErrFrameTooLarge is returned by [ReadFrame] when the incoming frame's
// declared length exceeds [MaxFrameSize].
var ErrFrameTooLarge = errors.New("ipc: frame exceeds maximum size")

// Standard JSON-RPC 2.0 error codes plus OFE-specific extensions in the
// implementation-defined range (-32000 to -32099, per the spec).
const (
	// CodeParseError indicates the server received invalid JSON.
	CodeParseError = -32700
	// CodeInvalidRequest indicates the payload is not a valid Request.
	CodeInvalidRequest = -32600
	// CodeMethodNotFound indicates no handler is registered for the
	// requested method name.
	CodeMethodNotFound = -32601
	// CodeInvalidParams indicates the handler could not decode the
	// request's params field.
	CodeInvalidParams = -32602
	// CodeInternalError is the catch-all for unexpected server errors.
	CodeInternalError = -32603
	// CodeHandlerError is returned when a registered handler returns a
	// non-nil error. The error's message is forwarded in
	// [ErrorObject.Message].
	CodeHandlerError = -32000
)

// Request is a JSON-RPC 2.0 request. ID is omitted for notifications,
// but the daemon's handlers always operate request/response.
type Request struct {
	// JSONRPC must equal [JSONRPCVersion].
	JSONRPC string `json:"jsonrpc"`
	// Method is the registered handler name (for example "status",
	// "account.list").
	Method string `json:"method"`
	// Params carries the method-specific payload. Handlers receive it
	// unparsed so they can decode it into their own struct shape.
	Params json.RawMessage `json:"params,omitempty"`
	// ID echoes back on the Response. It is opaque to the server.
	ID json.RawMessage `json:"id,omitempty"`
}

// Response is a JSON-RPC 2.0 response. Exactly one of Result or Error
// must be set; the spec forbids both being present.
type Response struct {
	// JSONRPC must equal [JSONRPCVersion].
	JSONRPC string `json:"jsonrpc"`
	// Result is the handler's return value, JSON-encoded.
	Result json.RawMessage `json:"result,omitempty"`
	// Error is set when the handler failed or the request was malformed.
	Error *ErrorObject `json:"error,omitempty"`
	// ID mirrors the corresponding Request.ID.
	ID json.RawMessage `json:"id,omitempty"`
}

// ErrorObject is the JSON-RPC 2.0 error envelope.
type ErrorObject struct {
	// Code is one of the constants above, or a custom code in the
	// implementation-defined range.
	Code int `json:"code"`
	// Message is a short human-readable string.
	Message string `json:"message"`
	// Data is optional structured detail (stack trace, conflicting
	// alias, etc.). Encoded only when non-nil.
	Data any `json:"data,omitempty"`
}

// Error implements the error interface so an [ErrorObject] can be
// returned directly from client-side code.
func (e *ErrorObject) Error() string {
	if e == nil {
		return "<nil ipc error>"
	}
	return fmt.Sprintf("ipc: %d %s", e.Code, e.Message)
}

// WriteFrame writes payload to w prefixed with its 4-byte big-endian
// length. It rejects payloads larger than [MaxFrameSize] before doing
// any IO.
func WriteFrame(w io.Writer, payload []byte) error {
	if len(payload) > MaxFrameSize {
		return fmt.Errorf("%w: have %d bytes", ErrFrameTooLarge, len(payload))
	}
	var header [4]byte
	// #nosec G115 -- len bounded by MaxFrameSize above, safe for uint32.
	binary.BigEndian.PutUint32(header[:], uint32(len(payload)))
	if _, err := w.Write(header[:]); err != nil {
		return fmt.Errorf("write frame header: %w", err)
	}
	if _, err := w.Write(payload); err != nil {
		return fmt.Errorf("write frame body: %w", err)
	}
	return nil
}

// ReadFrame reads one length-prefixed frame from r. It returns
// [ErrFrameTooLarge] if the declared length exceeds [MaxFrameSize] and
// io.EOF if the stream ends cleanly between frames.
func ReadFrame(r io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(header[:])
	if n > MaxFrameSize {
		return nil, fmt.Errorf("%w: declared %d bytes", ErrFrameTooLarge, n)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, fmt.Errorf("read frame body: %w", err)
	}
	return buf, nil
}

// EncodeRequest serialises req into the on-wire JSON form and returns
// the bytes. It is a thin wrapper around json.Marshal that pins the
// JSONRPC field, so callers cannot forget to set it.
func EncodeRequest(req *Request) ([]byte, error) {
	if req.JSONRPC == "" {
		req.JSONRPC = JSONRPCVersion
	}
	return json.Marshal(req)
}

// EncodeResponse serialises resp into the on-wire JSON form.
func EncodeResponse(resp *Response) ([]byte, error) {
	if resp.JSONRPC == "" {
		resp.JSONRPC = JSONRPCVersion
	}
	return json.Marshal(resp)
}

// DecodeRequest parses one Request from data.
func DecodeRequest(data []byte) (*Request, error) {
	var req Request
	if err := json.Unmarshal(data, &req); err != nil {
		return nil, fmt.Errorf("decode request: %w", err)
	}
	return &req, nil
}

// DecodeResponse parses one Response from data.
func DecodeResponse(data []byte) (*Response, error) {
	var resp Response
	if err := json.Unmarshal(data, &resp); err != nil {
		return nil, fmt.Errorf("decode response: %w", err)
	}
	return &resp, nil
}
