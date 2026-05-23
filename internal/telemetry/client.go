package telemetry

import (
	"context"
	"log/slog"
	"runtime"
	"sync"
	"time"
)

// Default tuning knobs. Sized for the catalogue in docs/telemetry.md
// (event throughput is modest; flush latency is not user-visible).
const (
	defaultFlushInterval = 10 * time.Second
	defaultMaxBufferSize = 1000
)

// Options configures New. AppVersion and InstallID are always merged
// into every event as common properties. Sink must be non-nil; pass
// NoopSink{} for the disabled state.
type Options struct {
	// AppVersion is the OFEM release version (typically buildinfo.Version).
	AppVersion string

	// InstallID is the per-install UUID (from EnsureInstallID).
	InstallID string

	// Sink is the transport. Required.
	Sink Sink

	// FlushInterval governs the background flush cadence. Defaults to
	// 10s when zero.
	FlushInterval time.Duration

	// MaxBufferSize is the in-memory event cap. Defaults to 1000. When
	// the buffer reaches this size, the oldest event is dropped to make
	// room for the new one and a debug log line is emitted.
	MaxBufferSize int

	// Logger receives debug/warn messages. Defaults to slog.Default.
	Logger *slog.Logger

	// OSVersion overrides the auto-detected macOS version. Tests set
	// this to keep the snapshot deterministic; production callers leave
	// it empty.
	OSVersion string

	// Platform / Arch override the runtime defaults. Tests set these;
	// production callers leave them empty so we report the real values.
	Platform string
	Arch     string
}

// Client is the public telemetry façade. Track enqueues; a background
// goroutine flushes to the configured Sink.
type Client struct {
	sink        Sink
	logger      *slog.Logger
	flushPeriod time.Duration
	maxBuffer   int
	commonProps map[string]string

	mu        sync.Mutex
	buffer    []Event
	closed    bool
	flushPing chan struct{} // non-blocking signal to wake the flusher

	wg     sync.WaitGroup
	cancel context.CancelFunc
}

// New constructs a Client. It does NOT start the background flusher;
// call Start for that. New returns nil only when Sink is nil.
func New(opts Options) *Client {
	if opts.Sink == nil {
		return nil
	}
	if opts.FlushInterval <= 0 {
		opts.FlushInterval = defaultFlushInterval
	}
	if opts.MaxBufferSize <= 0 {
		opts.MaxBufferSize = defaultMaxBufferSize
	}
	logger := opts.Logger
	if logger == nil {
		logger = slog.Default()
	}

	platform := opts.Platform
	if platform == "" {
		platform = runtime.GOOS
	}
	arch := opts.Arch
	if arch == "" {
		arch = runtime.GOARCH
	}
	osv := opts.OSVersion
	if osv == "" {
		osv = OSVersion()
	}

	common := map[string]string{
		"installId":  opts.InstallID,
		"appVersion": opts.AppVersion,
		"platform":   platform,
		"arch":       arch,
		"osVersion":  osv,
	}

	return &Client{
		sink:        opts.Sink,
		logger:      logger,
		flushPeriod: opts.FlushInterval,
		maxBuffer:   opts.MaxBufferSize,
		commonProps: common,
		flushPing:   make(chan struct{}, 1),
	}
}

// Start launches the background flusher. It returns immediately. Pass a
// long-lived context (typically the daemon's root context); Close stops
// the goroutine cleanly regardless.
func (c *Client) Start(ctx context.Context) {
	if c == nil {
		return
	}
	if _, ok := c.sink.(NoopSink); ok {
		// Nothing to flush; skip the goroutine entirely.
		return
	}
	loopCtx, cancel := context.WithCancel(ctx)
	c.mu.Lock()
	c.cancel = cancel
	c.mu.Unlock()
	c.wg.Add(1)
	go c.run(loopCtx)
}

// Track enqueues an event. Common properties (install ID, app version,
// platform, arch, OS version) are merged in; Time defaults to now.
// Track is non-blocking and safe for concurrent use. When the buffer is
// full the oldest event is dropped to make room.
func (c *Client) Track(event Event) {
	if c == nil {
		return
	}

	if event.Time.IsZero() {
		event.Time = time.Now().UTC()
	}
	// Clone the caller-supplied CommonProps before merging so we never
	// mutate a map the caller still holds a reference to.
	src := event.CommonProps
	merged := make(map[string]string, len(src)+len(c.commonProps))
	for k, v := range src {
		merged[k] = v
	}
	for k, v := range c.commonProps {
		if _, ok := merged[k]; ok {
			continue // caller-supplied value wins
		}
		merged[k] = v
	}
	event.CommonProps = merged

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	if len(c.buffer) >= c.maxBuffer {
		// Drop the oldest event to make room. Re-slicing rather than
		// copying keeps Track O(1) under load; the buffer eventually
		// compacts when Flush reassigns it to nil.
		dropped := c.buffer[0]
		c.buffer = c.buffer[1:]
		c.logger.Debug("telemetry buffer overflow; dropped oldest event",
			"dropped_event", dropped.Name,
			"max_buffer", c.maxBuffer,
		)
	}
	c.buffer = append(c.buffer, event)
	full := len(c.buffer) >= c.maxBuffer
	c.mu.Unlock()

	if full {
		c.signalFlush()
	}
}

// TrackError is a shortcut for emitting the "error" event with a scrubbed
// error code and the originating operation name.
func (c *Client) TrackError(err error, op string) {
	if c == nil || err == nil {
		return
	}
	c.Track(Event{
		Name:      "error",
		ErrorCode: SafeErrorCode(err.Error()),
		CommonProps: map[string]string{
			"failedOp": op,
		},
	})
}

// Flush ships any buffered events to the Sink synchronously. It returns
// the Sink's error verbatim. On Send failure the in-flight batch is put
// back at the front of the buffer (so the next Flush retries it),
// capped by the same overflow policy as Track — oldest events are
// dropped when the buffer would exceed maxBuffer. Safe to call after
// Close; subsequent calls will still attempt to drain whatever was
// re-queued by an earlier failed Send.
func (c *Client) Flush(ctx context.Context) error {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	batch := c.buffer
	c.buffer = nil
	c.mu.Unlock()
	if len(batch) == 0 {
		return nil
	}
	if err := c.sink.Send(ctx, batch); err != nil {
		c.mu.Lock()
		// Re-queue the failed batch in front of anything Track added
		// while Send was in flight, then trim to cap from the oldest end.
		// This matches the docs/telemetry.md promise that events
		// accumulate up to maxBuffer and only get dropped on overflow.
		// We re-queue even during shutdown: Close cancels the loop ctx
		// first (which can fail an in-flight Send with ctx.Cancelled)
		// and then issues a final Flush with the shutdown deadline that
		// will pick up the re-queued batch. Track is already a no-op
		// once closed=true, so nothing new gets in front.
		c.buffer = append(batch, c.buffer...)
		if over := len(c.buffer) - c.maxBuffer; over > 0 {
			c.buffer = c.buffer[over:]
			c.logger.Debug("telemetry buffer overflow after failed flush; dropped oldest events",
				"dropped", over,
				"max_buffer", c.maxBuffer,
			)
		}
		c.mu.Unlock()
		c.logger.Warn("telemetry flush failed", "err", err, "events", len(batch))
		return err
	}
	return nil
}

// Close stops the background flusher and performs a final flush. The
// provided context bounds the final flush — callers typically pass a
// short shutdown deadline. After Close, Track becomes a no-op.
func (c *Client) Close(ctx context.Context) error {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	cancel := c.cancel
	c.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	c.wg.Wait()

	return c.Flush(ctx)
}

// run is the background flusher loop.
func (c *Client) run(ctx context.Context) {
	defer c.wg.Done()
	ticker := time.NewTicker(c.flushPeriod)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			// Intentional: do NOT flush here. Both shutdown paths run
			// their own final drain — Close cancels this ctx and then
			// calls Flush with the shutdown deadline; if the parent ctx
			// is cancelled directly (e.g. SIGTERM), Close still calls
			// Flush after wg.Wait. Flushing here with an already-dead
			// ctx would just fail the Send and re-queue.
			return
		case <-ticker.C:
			if err := c.Flush(ctx); err != nil {
				// Already logged; loop continues.
				continue
			}
		case <-c.flushPing:
			if err := c.Flush(ctx); err != nil {
				continue
			}
		}
	}
}

// signalFlush nudges the background goroutine to flush right away. The
// channel is buffered (size 1) so repeated signals coalesce.
func (c *Client) signalFlush() {
	select {
	case c.flushPing <- struct{}{}:
	default:
	}
}
