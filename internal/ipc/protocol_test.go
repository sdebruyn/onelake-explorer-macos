package ipc

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name    string
		payload []byte
	}{
		{name: "empty", payload: []byte{}},
		{name: "small", payload: []byte(`{"jsonrpc":"2.0","method":"status"}`)},
		{name: "binary-ish", payload: []byte{0x00, 0xff, 0x10, 0x20, 0x7f}},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			var buf bytes.Buffer
			if err := WriteFrame(&buf, tc.payload); err != nil {
				t.Fatalf("WriteFrame: %v", err)
			}
			got, err := ReadFrame(&buf)
			if err != nil {
				t.Fatalf("ReadFrame: %v", err)
			}
			if !bytes.Equal(got, tc.payload) {
				t.Fatalf("round-trip mismatch: got %x want %x", got, tc.payload)
			}
		})
	}
}

func TestFrameMultipleSequential(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	frames := [][]byte{[]byte("alpha"), []byte("beta"), []byte("gamma")}
	for _, f := range frames {
		if err := WriteFrame(&buf, f); err != nil {
			t.Fatalf("write %q: %v", f, err)
		}
	}
	for i, want := range frames {
		got, err := ReadFrame(&buf)
		if err != nil {
			t.Fatalf("read frame %d: %v", i, err)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("frame %d: got %q want %q", i, got, want)
		}
	}
	if _, err := ReadFrame(&buf); !errors.Is(err, io.EOF) {
		t.Fatalf("expected EOF after final frame, got %v", err)
	}
}

func TestWriteFrameRejectsOversize(t *testing.T) {
	t.Parallel()

	payload := bytes.Repeat([]byte{0x41}, MaxFrameSize+1)
	var buf bytes.Buffer
	err := WriteFrame(&buf, payload)
	if !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("WriteFrame: want ErrFrameTooLarge, got %v", err)
	}
	if buf.Len() != 0 {
		t.Fatalf("WriteFrame should not have written anything; got %d bytes", buf.Len())
	}
}

func TestReadFrameRejectsOversize(t *testing.T) {
	t.Parallel()

	var header [4]byte
	binary.BigEndian.PutUint32(header[:], MaxFrameSize+1)
	r := bytes.NewReader(header[:])
	_, err := ReadFrame(r)
	if !errors.Is(err, ErrFrameTooLarge) {
		t.Fatalf("ReadFrame: want ErrFrameTooLarge, got %v", err)
	}
}

func TestReadFrameTruncatedHeader(t *testing.T) {
	t.Parallel()

	r := bytes.NewReader([]byte{0x00, 0x01}) // 2 bytes, want 4
	_, err := ReadFrame(r)
	if err == nil {
		t.Fatalf("expected error reading truncated header, got nil")
	}
}

func TestReadFrameTruncatedBody(t *testing.T) {
	t.Parallel()

	var header [4]byte
	binary.BigEndian.PutUint32(header[:], 10)
	r := bytes.NewReader(append(header[:], []byte("abc")...)) // only 3 of 10 bytes
	_, err := ReadFrame(r)
	if err == nil {
		t.Fatalf("expected error reading truncated body, got nil")
	}
}

func TestEncodeDecodeRequest(t *testing.T) {
	t.Parallel()

	req := &Request{Method: "status", ID: json.RawMessage(`"abc"`)}
	encoded, err := EncodeRequest(req)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if !strings.Contains(string(encoded), `"jsonrpc":"2.0"`) {
		t.Fatalf("encoded payload missing jsonrpc field: %s", encoded)
	}
	decoded, err := DecodeRequest(encoded)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if decoded.Method != "status" {
		t.Fatalf("method round-trip: got %q want status", decoded.Method)
	}
	if string(decoded.ID) != `"abc"` {
		t.Fatalf("id round-trip: got %s want \"abc\"", decoded.ID)
	}
}

func TestEncodeDecodeResponseError(t *testing.T) {
	t.Parallel()

	resp := &Response{
		Error: &ErrorObject{Code: CodeMethodNotFound, Message: "no"},
		ID:    json.RawMessage(`1`),
	}
	encoded, err := EncodeResponse(resp)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	decoded, err := DecodeResponse(encoded)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if decoded.Error == nil || decoded.Error.Code != CodeMethodNotFound {
		t.Fatalf("error round-trip: got %+v", decoded.Error)
	}
	if decoded.Error.Error() == "" {
		t.Fatalf("ErrorObject.Error returned empty string")
	}
}
