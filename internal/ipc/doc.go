// Package ipc implements the JSON-RPC 2.0 transport that connects the OFEM
// CLI, host app, and File Provider Extension to the background daemon.
//
// Transport details:
//   - Unix domain socket, owner-only permissions (0600).
//   - Length-prefixed frames: 4-byte big-endian length followed by the
//     UTF-8 JSON payload. Frames cap at [MaxFrameSize] to keep a buggy or
//     malicious peer from exhausting daemon memory.
//   - One goroutine per connection. Multiple in-flight requests on the
//     same connection are not supported by clients in this package, but
//     the server tolerates pipelined requests.
//
// The wire format intentionally mirrors JSON-RPC 2.0 so we can adopt
// future tooling (debug consoles, third-party CLIs) without inventing our
// own protocol. The framing layer is custom because JSON-RPC 2.0 has no
// official transport binding for Unix sockets — only Content-Length
// framing (HTTP-style) and embedded line-delimited variants — and a fixed
// 4-byte length prefix is the simplest robust choice for a binary stream.
package ipc
