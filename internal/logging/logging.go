// Package logging configures slog for the CLI and daemon. The CLI logs to
// stderr with a human-readable format; the daemon logs JSON to a rotating
// file in ~/Library/Group Containers/group.dev.debruyn.ofem/log/.
package logging

import (
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
)

// Mode selects the logger flavor.
type Mode int

const (
	// ModeCLI writes human-readable text to stderr. For interactive commands.
	ModeCLI Mode = iota
	// ModeDaemon writes JSON to the provided sink (usually a rotating file).
	ModeDaemon
)

// Options configures Setup. Level is "debug", "info", "warn", "error".
type Options struct {
	Mode  Mode
	Level string
	Sink  io.Writer // ignored for ModeCLI (always stderr)
}

// Setup returns a slog.Logger configured for the chosen mode. It also
// installs it as the slog default, so packages can call slog.Info directly.
func Setup(opts Options) (*slog.Logger, error) {
	lvl, err := parseLevel(opts.Level)
	if err != nil {
		return nil, err
	}

	var handler slog.Handler
	switch opts.Mode {
	case ModeCLI:
		handler = slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: lvl})
	case ModeDaemon:
		sink := opts.Sink
		if sink == nil {
			sink = os.Stderr
		}
		handler = slog.NewJSONHandler(sink, &slog.HandlerOptions{Level: lvl})
	default:
		return nil, fmt.Errorf("unknown logging mode %v", opts.Mode)
	}

	logger := slog.New(handler)
	slog.SetDefault(logger)
	return logger, nil
}

func parseLevel(s string) (slog.Level, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "info":
		return slog.LevelInfo, nil
	case "debug":
		return slog.LevelDebug, nil
	case "warn", "warning":
		return slog.LevelWarn, nil
	case "error":
		return slog.LevelError, nil
	default:
		return 0, fmt.Errorf("invalid log level %q (want debug|info|warn|error)", s)
	}
}
