import Foundation

// MARK: - Duration.seconds (sync-10)

/// Shared extension replacing the two private copies that were duplicated
/// verbatim in `PauseManager.swift` and `OfflineTracker.swift` (sync-10).
extension Duration {
    /// The duration expressed as a `TimeInterval` (seconds, with sub-second
    /// precision carried by the attosecond component).
    var seconds: TimeInterval {
        let (sec, attosec) = components
        return TimeInterval(sec) + TimeInterval(attosec) / 1e18
    }
}
