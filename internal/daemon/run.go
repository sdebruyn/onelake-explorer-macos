package daemon

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	lumberjack "gopkg.in/natefinch/lumberjack.v2"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
	"github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo"
	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
	"github.com/sdebruyn/onelake-explorer-macos/internal/fabric"
	"github.com/sdebruyn/onelake-explorer-macos/internal/ipc"
	"github.com/sdebruyn/onelake-explorer-macos/internal/logging"
	"github.com/sdebruyn/onelake-explorer-macos/internal/onelake"
	"github.com/sdebruyn/onelake-explorer-macos/internal/sync"
	"github.com/sdebruyn/onelake-explorer-macos/internal/telemetry"
)

// LogFileName is the file under the OFEM log directory that the daemon
// writes its JSON slog stream to.
const LogFileName = "ofem.log"

// telemetryShutdownTimeout bounds the final telemetry flush at process
// exit. Two seconds is plenty for App Insights' v2/track endpoint under
// normal conditions and short enough that a misbehaving network never
// blocks daemon shutdown.
const telemetryShutdownTimeout = 2 * time.Second

// pollerHotWindow is the look-back window the adaptive poller uses to
// decide which items are "recent". Per docs/auth.md the daemon refreshes
// recently-visited folders every RecentFolderTTL (5 min); we consider
// an item recent if any of its rows was accessed within the last
// 30 minutes. That window matches what Finder typically holds open and
// keeps the poller's work bounded.
const pollerHotWindow = 30 * time.Minute

// Defaults for the rotating log writer. Picked to be small enough that
// the daemon never fills a user's disk and large enough that a few days
// of debug logging fits in the most recent file.
const (
	logMaxMegabytes = 5
	logMaxBackups   = 3
	logCompress     = true
)

// RunOptions tweaks Run for tests and embedded callers. Production
// callers should use [Run] with the zero value and let it pick all
// defaults from the loaded config.
type RunOptions struct {
	// Store overrides config.Load. When nil, Run loads from disk.
	Store *config.Store
	// LogWriter overrides the default file-rotating writer. When nil,
	// Run constructs a lumberjack writer at <LogDir>/ofem.log.
	LogWriter func(paths config.Paths) (logSink, error)
	// SocketPath overrides config.Paths.SocketPath. Used in tests.
	SocketPath string
	// KeychainOverride is used in tests to inject an in-memory keychain.
	// nil means use the real macOS keychain.
	KeychainOverride auth.Keychain
}

// logSink is the subset of io.WriteCloser our log rotation needs. The
// lumberjack writer satisfies it; tests can pass a bytes.Buffer wrapper.
type logSink interface {
	Write(p []byte) (int, error)
	Close() error
}

// Run is the foreground entry point invoked by `ofem daemon run` (which
// the LaunchAgent calls under launchd). It wires up logging, cache, and
// the IPC server, then blocks until SIGINT or SIGTERM. It returns the
// first fatal setup error, or nil on a clean shutdown.
func Run(ctx context.Context, opts RunOptions) error {
	store := opts.Store
	if store == nil {
		s, err := config.Load()
		if err != nil {
			return fmt.Errorf("daemon: load config: %w", err)
		}
		store = s
	}
	paths := store.Paths()
	cfg := store.Snapshot()

	// Logging first so subsequent errors land in the log file.
	writerFn := opts.LogWriter
	if writerFn == nil {
		writerFn = defaultLogWriter
	}
	sink, err := writerFn(paths)
	if err != nil {
		return fmt.Errorf("daemon: open log: %w", err)
	}
	defer func() { _ = sink.Close() }()

	logger, err := logging.Setup(logging.Options{
		Mode:  logging.ModeDaemon,
		Level: cfg.Log.Level,
		Sink:  sink,
	})
	if err != nil {
		return fmt.Errorf("daemon: configure logging: %w", err)
	}
	logger = logger.With(slog.String("component", "daemon"))

	// Cache next so handler wiring can use it.
	if err := os.MkdirAll(paths.CacheDir, 0o700); err != nil {
		return fmt.Errorf("daemon: create cache dir: %w", err)
	}
	c, err := cache.Open(cache.Options{
		Root:         paths.CacheDir,
		MaxBlobBytes: cfg.Cache.MaxSizeBytes,
	})
	if err != nil {
		return fmt.Errorf("daemon: open cache: %w", err)
	}
	defer func() { _ = c.Close() }()

	// Auth registry. We pass it the same store so the daemon and CLI
	// stay in sync — both read and mutate config.toml under the same
	// lock. The registry implements [auth.TokenProvider] directly, so
	// the Fabric and OneLake clients can consume it without an adapter.
	kc := opts.KeychainOverride
	if kc == nil {
		built, err := auth.NewKeychain()
		if err != nil {
			return fmt.Errorf("open keychain: %w", err)
		}
		kc = built
	}
	registry := auth.NewRegistry(store, kc, auth.EntraClientID, nil)

	// Telemetry. Init returns a no-op client whenever telemetry is
	// disabled (env, config flag, or unset connection string) so the
	// rest of the wiring can call Track unconditionally. On unexpected
	// failure we keep the daemon up with a no-op fallback so a broken
	// telemetry pipeline never blocks file access.
	tel, terr := telemetry.Init(ctx, store, logger)
	if terr != nil {
		logger.Warn("telemetry init failed; continuing without it", slog.Any("err", terr))
		tel = telemetry.New(telemetry.Options{
			AppVersion: buildinfo.Version,
			Sink:       telemetry.NoopSink{},
			Logger:     logger,
		})
	}
	defer func() {
		// Bound both the final app_stop emission and the sink drain by a
		// single 2-second deadline so a misbehaving network never blocks
		// daemon shutdown. Track is non-blocking (it just enqueues), but
		// Close performs the actual flush — sharing the context ensures
		// the flush picks up the app_stop event we just queued.
		closeCtx, cancel := context.WithTimeout(context.Background(), telemetryShutdownTimeout)
		defer cancel()
		tel.Track(telemetry.Event{Name: "app_stop"})
		if err := tel.Close(closeCtx); err != nil {
			logger.Warn("telemetry close error", slog.Any("err", err))
		}
	}()
	tel.Track(telemetry.Event{Name: "app_start"})

	// Sync engine. Stitch the Fabric REST and OneLake DFS clients to
	// the same token provider and feed both into the engine alongside
	// the cache and telemetry client. New only errors when a required
	// dependency is missing, which would be a programmer error here.
	fabricClient := fabric.New(fabric.Options{TokenProvider: registry})
	onelakeClient := onelake.New(onelake.Options{TokenProvider: registry})
	engine, err := sync.New(sync.Options{
		Cache:     c,
		Fabric:    fabricClient,
		OneLake:   onelakeClient,
		Telemetry: tel,
		Tenants:   registry,
		Logger:    logger,
	})
	if err != nil {
		return fmt.Errorf("daemon: build sync engine: %w", err)
	}

	// IPC server.
	srv := ipc.NewServer(logger)
	NewHandlers(store, registry, c, engine).Register(srv)

	sockPath := opts.SocketPath
	if sockPath == "" {
		sockPath = paths.SocketPath
	}

	// Translate SIGINT/SIGTERM into context cancellation so a single
	// path covers both manual ctrl-C and `launchctl kill SIGTERM`.
	runCtx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()

	listenErr := make(chan error, 1)
	go func() { listenErr <- srv.Listen(runCtx, sockPath) }()

	// Wait for the listener to be bound before logging "ready".
	select {
	case <-srv.Ready():
		if srv.SocketPath() == "" {
			// Bind failed; wait for the error to surface.
			err := <-listenErr
			return fmt.Errorf("daemon: bind socket: %w", err)
		}
		logger.Info("daemon ready",
			slog.String("socket", srv.SocketPath()),
			slog.String("cache_dir", paths.CacheDir),
			slog.String("version", versionString()),
		)
	case err := <-listenErr:
		return fmt.Errorf("daemon: listen: %w", err)
	}

	// Adaptive poller: refresh recently-touched items at the
	// RecentFolderTTL cadence. The goroutine respects runCtx so it
	// unwinds on shutdown.
	pollerDone := make(chan struct{})
	go func() {
		defer close(pollerDone)
		runAdaptivePoller(runCtx, c, engine, logger, engine.RecentFolderTTL(), pollerHotWindow)
	}()

	// Block until either signal cancellation or the listener exits
	// unexpectedly. We Close() the server explicitly so the deferred
	// cache and log closers run in the right order.
	var exitErr error
	select {
	case <-runCtx.Done():
		logger.Info("daemon shutdown signal received")
	case err := <-listenErr:
		if err != nil && !errors.Is(err, context.Canceled) {
			exitErr = fmt.Errorf("daemon: listen exited: %w", err)
		}
	}

	// Cancel runCtx so the poller goroutine — which only returns on
	// runCtx.Done — unwinds in both shutdown paths (signal AND
	// unexpected listener exit). Without this, the listener-error path
	// would hang at <-pollerDone forever waiting on a goroutine whose
	// loop has no other reason to return.
	stop()

	// Wait for the poller to unwind so its in-flight work doesn't race
	// the cache.Close defer.
	<-pollerDone

	if err := srv.Close(); err != nil {
		logger.Warn("ipc server close error", slog.Any("err", err))
	}
	// Drain listenErr if it hasn't fired yet. Anything that arrives
	// here is expected (Listener.Close races acceptLoop and the
	// listener returns a "use of closed network connection" error
	// that is not actionable), but we log at debug so it isn't
	// invisible during diagnosis.
	select {
	case err := <-listenErr:
		if err != nil {
			logger.Debug("ipc listener drained post-close", slog.Any("err", err))
		}
	default:
	}
	return exitErr
}

// versionString returns the buildinfo.Version baked into the daemon at
// link time, surfaced in the startup log line.
func versionString() string { return buildinfo.Version }

// defaultLogWriter constructs the production rotating file writer. It
// is exposed via the RunOptions.LogWriter hook so tests can substitute
// an in-memory sink.
func defaultLogWriter(paths config.Paths) (logSink, error) {
	if err := os.MkdirAll(paths.LogDir, 0o700); err != nil {
		return nil, fmt.Errorf("create log dir: %w", err)
	}
	return &lumberjack.Logger{
		Filename:   filepath.Join(paths.LogDir, LogFileName),
		MaxSize:    logMaxMegabytes,
		MaxBackups: logMaxBackups,
		Compress:   logCompress,
	}, nil
}
