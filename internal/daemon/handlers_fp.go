package daemon

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/sdebruyn/onelake-explorer-macos/internal/fp"
)

// File Provider IPC surface. These methods replace the cgo bridge: the
// sandboxed extension calls them over the same unix socket the CLI uses,
// and the daemon — the single owner of the engine and cache — serves them.
//
// Each handler returns an [fp.Envelope] as the JSON-RPC result. Domain
// errors (missing item, paused capacity, offline, …) travel INSIDE the
// envelope as a classified code so the extension decodes one shape
// regardless of outcome; a non-nil Go error is reserved for protocol-level
// failures (undecodable params), which surface as a JSON-RPC error.

type fpEnumerateRequest struct {
	Alias      string `json:"alias"`
	Identifier string `json:"identifier"`
	// Cursor is the opaque pagination token from a previous fp.enumerate
	// response. Empty or absent means "start from the beginning".
	Cursor string `json:"cursor,omitempty"`
}

// fpEnumerateResponse carries the items for one page and the cursor to fetch
// the next page. NextCursor is empty when this is the final page. The JSON
// field names are part of the IPC contract with the Swift File Provider
// Extension; do not rename them without a matching Swift-side update.
type fpEnumerateResponse struct {
	Items      []fp.Item `json:"items"`
	NextCursor string    `json:"nextCursor"`
}

type fpItemRequest struct {
	Alias      string `json:"alias"`
	Identifier string `json:"identifier"`
}

type fpFetchRequest struct {
	Alias      string `json:"alias"`
	Identifier string `json:"identifier"`
	// DestPath is where the daemon writes the fetched bytes. It MUST be a
	// location both the daemon and the calling extension can reach — the
	// App Group container — since the extension reads it back to hand to
	// macOS.
	DestPath string `json:"destPath"`
}

type fpCreateRequest struct {
	Alias            string `json:"alias"`
	ParentIdentifier string `json:"parentIdentifier"`
	Filename         string `json:"filename"`
	IsDir            bool   `json:"isDir"`
	SrcPath          string `json:"srcPath"`
}

type fpModifyRequest struct {
	Alias      string `json:"alias"`
	Identifier string `json:"identifier"`
	SrcPath    string `json:"srcPath"`
}

type fpDeleteRequest struct {
	Alias      string `json:"alias"`
	Identifier string `json:"identifier"`
}

// fpErr wraps a not-wired engine as an envelope so the extension always
// gets a decodable result even in degraded configurations.
func (h *Handlers) fpReady() (*fp.Service, bool) {
	if !h.fpOK || h.fp == nil {
		return nil, false
	}
	return h.fp, true
}

func (h *Handlers) handleFPEnumerate(ctx context.Context, params json.RawMessage) (any, error) {
	var req fpEnumerateRequest
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, fmt.Errorf("fp.enumerate: decode params: %w", err)
	}
	svc, ok := h.fpReady()
	if !ok {
		return fp.ErrorEnvelope(ErrEngineNotWired), nil
	}
	page, err := svc.EnumeratePaged(ctx, req.Alias, req.Identifier, req.Cursor)
	if err != nil {
		return fp.ErrorEnvelope(err), nil
	}
	items := page.Items
	if items == nil {
		items = []fp.Item{}
	}
	return fpEnumerateResponse{Items: items, NextCursor: page.NextCursor}, nil
}

func (h *Handlers) handleFPItem(ctx context.Context, params json.RawMessage) (any, error) {
	var req fpItemRequest
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, fmt.Errorf("fp.item: decode params: %w", err)
	}
	svc, ok := h.fpReady()
	if !ok {
		return fp.ErrorEnvelope(ErrEngineNotWired), nil
	}
	item, err := svc.Item(ctx, req.Alias, req.Identifier)
	if err != nil {
		return fp.ErrorEnvelope(err), nil
	}
	return fp.Envelope{Item: &item}, nil
}

func (h *Handlers) handleFPFetchContents(ctx context.Context, params json.RawMessage) (any, error) {
	var req fpFetchRequest
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, fmt.Errorf("fp.fetchContents: decode params: %w", err)
	}
	svc, ok := h.fpReady()
	if !ok {
		return fp.ErrorEnvelope(ErrEngineNotWired), nil
	}
	item, err := svc.FetchContents(ctx, req.Alias, req.Identifier, req.DestPath)
	if err != nil {
		return fp.ErrorEnvelope(err), nil
	}
	return fp.Envelope{Item: &item}, nil
}

func (h *Handlers) handleFPCreateItem(ctx context.Context, params json.RawMessage) (any, error) {
	var req fpCreateRequest
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, fmt.Errorf("fp.createItem: decode params: %w", err)
	}
	svc, ok := h.fpReady()
	if !ok {
		return fp.ErrorEnvelope(ErrEngineNotWired), nil
	}
	item, err := svc.CreateItem(ctx, req.Alias, req.ParentIdentifier, req.Filename, req.IsDir, req.SrcPath)
	if err != nil {
		return fp.ErrorEnvelope(err), nil
	}
	return fp.Envelope{Item: &item}, nil
}

func (h *Handlers) handleFPModifyItem(ctx context.Context, params json.RawMessage) (any, error) {
	var req fpModifyRequest
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, fmt.Errorf("fp.modifyItem: decode params: %w", err)
	}
	svc, ok := h.fpReady()
	if !ok {
		return fp.ErrorEnvelope(ErrEngineNotWired), nil
	}
	item, err := svc.ModifyItem(ctx, req.Alias, req.Identifier, req.SrcPath)
	if err != nil {
		return fp.ErrorEnvelope(err), nil
	}
	return fp.Envelope{Item: &item}, nil
}

func (h *Handlers) handleFPDeleteItem(ctx context.Context, params json.RawMessage) (any, error) {
	var req fpDeleteRequest
	if err := json.Unmarshal(params, &req); err != nil {
		return nil, fmt.Errorf("fp.deleteItem: decode params: %w", err)
	}
	svc, ok := h.fpReady()
	if !ok {
		return fp.ErrorEnvelope(ErrEngineNotWired), nil
	}
	if err := svc.DeleteItem(ctx, req.Alias, req.Identifier); err != nil {
		return fp.ErrorEnvelope(err), nil
	}
	return fp.Envelope{}, nil
}
