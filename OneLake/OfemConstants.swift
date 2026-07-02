// OfemConstants.swift
// Compile-time constants shared across the host-app target.
//
// Centralises strings that were previously hand-typed in multiple files:
//   - Logger subsystem (was in 11 host files)
//   - Window scene identifiers
//
// Domain identifier composition (`ofemDomainIdentifierPrefix` and friends)
// and the setConfig key vocabulary (`OfemConfigKey`) live in `Shared/` —
// both the host and the FPE need them, and per-target copies previously let
// the two sides drift silently (xpc-09/xpc-10).

import Foundation

// MARK: - Subsystem

/// Logger subsystem used by every Logger in the host-app target.
let ofemSubsystem = "dev.debruyn.ofem"

// MARK: - Window identifiers

/// Scene id for the "Add Account" window. Must match the `Window(_, id:)` declaration
/// in OneLakeApp and the `openWindow(id:)` call site in MenuBarView.
let ofemAddAccountWindowID = "add-account"
