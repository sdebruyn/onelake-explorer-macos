// FPErrorMapping.swift
// Shared FPError.Code → NSFileProviderError conversion.
//
// One canonical mapping ensures that a code change (e.g. deciding .serverBusy
// should surface differently) is applied consistently at every FPE call site.

@preconcurrency import FileProvider
import OfemKit

/// Maps a stable ``FPError/Code`` to the corresponding `NSFileProviderError`.
///
/// All FPE call sites (``FileProviderExtension``, ``OfemFPEEnumerator``) must
/// use this function exclusively — never inline the switch.
func nsFileProviderError(for code: FPError.Code) -> Error {
    switch code {
    case .noSuchItem: NSFileProviderError(.noSuchItem)
    case .notAuthenticated: NSFileProviderError(.notAuthenticated)
    case .serverBusy: NSFileProviderError(.serverUnreachable)
    case .serverUnreachable: NSFileProviderError(.serverUnreachable)
    case .cannotSynchronize: NSFileProviderError(.cannotSynchronize)
    }
}
