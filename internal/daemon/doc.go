// Package daemon hosts the long-running OFEM background process. It
// owns the SQLite metadata cache, the IPC server, and (in later PRs)
// the sync engine that polls Fabric for changes and drives the File
// Provider Extension via XPC.
//
// In production the daemon runs under a LaunchAgent registered by the
// host app via SMAppService (see apple/OneLake/LoginItemManager.swift and
// apple/OneLake/LaunchAgents/dev.debruyn.ofem.daemon.plist). It can also
// be invoked directly with `./bin/ofem daemon run` for development and
// is what the IPC integration test spawns against a temp socket.
package daemon
