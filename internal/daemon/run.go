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

	lumberjack "gopkg.in/natefinch/lumberjack.v2"

	"github.com/sdebruyn/onelake-explorer-macos/internal/auth"
	"github.com/sdebruyn/onelake-explorer-macos/internal/buildinfo"
	"github.com/sdebruyn/onelake-explorer-macos/internal/cache"
	"github.com/sdebruyn/onelake-explorer-macos/internal/config"
	"github.com/sdebruyn/onelake-explorer-macos/internal/ipc"
	"github.com/sdebruyn/onelake-explorer-macos/internal/logging"
)

// LogFileName is the file under the OFE log directory that the daemon
// writes its JSON slog stream to.
const LogFileName = "ofe.log"

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
	// Run constructs a lumberjack writer at <LogDir>/ofe.log.
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

// Run is the foreground entry point invoked by `ofe daemon run` (which
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
	// lock. Token acquisition (Registry.Token) is intentionally NOT
	// used here; the MSAL silent-refresh wiring lands in a follow-up
	// PR and the daemon only needs the account-management surface for
	// now.
	kc := opts.KeychainOverride
	if kc == nil {
		kc = auth.NewKeychain()
	}
	registry := auth.NewRegistry(store, kc)

	// IPC server.
	srv := ipc.NewServer(logger)
	NewHandlers(store, registry, c).Register(srv)

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

	if err := srv.Close(); err != nil {
		logger.Warn("ipc server close error", slog.Any("err", err))
	}
	// Drain listenErr if it hasn't fired yet.
	select {
	case <-listenErr:
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
