import OfemKit

// Compile-time check that OfemKit is available in the host app.
private enum OfemKitProbe {
    static let version = OfemKit.version
}
