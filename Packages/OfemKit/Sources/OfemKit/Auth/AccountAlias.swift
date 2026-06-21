import Foundation

// MARK: - AccountAlias

/// Type-safe wrapper for a user-chosen account alias.
///
/// An alias is the short name an OFEM user assigns to one signed-in OneLake
/// account (e.g. `"work"`, `"client-a"`). It appears:
/// - as the suffix of the File Provider domain folder
/// (`~/Library/CloudStorage/OneLake-<alias>/`);
/// - as the first path segment of every `NSFileProviderItemIdentifier`;
/// - as the key in the TOML config `[accounts]` table;
/// - as the key in the MSAL token cache accessor.
///
/// The allowed character set is intentionally strict (ASCII letters, digits,
/// dash, underscore, dot; 1–32 characters) because the alias is embedded
/// in file-system paths and may be parsed by shells and URL parsers.
public struct AccountAlias: Hashable, Sendable, CustomStringConvertible {
    /// The validated raw alias string.
    public let rawValue: String

    public var description: String {
        rawValue
    }

    // MARK: - Initialisation

    /// Creates an `AccountAlias` after validating `rawValue`.
    ///
    /// - Parameter rawValue: The user-supplied alias string.
    /// - Throws: ``AccountAliasError`` if the alias is invalid.
    public init(_ rawValue: String) throws {
        try AccountAlias.validate(rawValue)
        self.rawValue = rawValue
    }

    // MARK: - Validation

    /// Maximum allowed alias length. Intentionally small because aliases
    /// appear in file-system paths.
    public static let maxLength = 32

    /// Returns without throwing when `alias` is safe to use as an account
    /// identifier; throws ``AccountAliasError`` otherwise.
    ///
    /// Rules:
    /// - Length: 1–32 characters.
    /// - First character must not be `-` (CLI flag risk) or `.` (hidden file).
    /// - Every character must be ASCII: letter, digit, `-`, `_`, or `.`.
    /// - The alias must not consist entirely of `.` characters (path traversal risk).
    public static func validate(_ alias: String) throws {
        guard !alias.isEmpty else {
            throw AccountAliasError.empty
        }
        guard alias.count <= maxLength else {
            throw AccountAliasError.tooLong(alias, maxLength)
        }
        guard let first = alias.unicodeScalars.first else {
            throw AccountAliasError.empty
        }
        if first == UnicodeScalar(UInt8(ascii: "-")) {
            throw AccountAliasError.startsWithDash(alias)
        }
        if first == UnicodeScalar(UInt8(ascii: ".")) {
            throw AccountAliasError.startsWithDot(alias)
        }
        for scalar in alias.unicodeScalars {
            let v = scalar.value
            let isLetter = (v >= 65 && v <= 90) || (v >= 97 && v <= 122) // A-Z, a-z
            let isDigit = v >= 48 && v <= 57 // 0-9
            let isAllowed = isLetter || isDigit || v == 45 || v == 95 || v == 46 // -, _, .
            guard isAllowed else {
                throw AccountAliasError.disallowedCharacter(alias, scalar)
            }
        }
        // Reject all-dots aliases: ".", "..", "..." etc.
        if alias.unicodeScalars.allSatisfy({ $0.value == 46 }) {
            throw AccountAliasError.allDots(alias)
        }
    }
}

// MARK: - AccountAliasError

/// Errors thrown by ``AccountAlias/init(_:)`` and ``AccountAlias/validate(_:)``.
public enum AccountAliasError: Error, CustomStringConvertible {
    case empty
    case tooLong(String, Int)
    case startsWithDash(String)
    case startsWithDot(String)
    case disallowedCharacter(String, Unicode.Scalar)
    case allDots(String)

    public var description: String {
        switch self {
        case .empty:
            "alias must not be empty"
        case let .tooLong(alias, max):
            "alias \"\(alias)\" is longer than \(max) characters"
        case let .startsWithDash(alias):
            "alias \"\(alias)\" must not start with '-' (would be parsed as a CLI flag)"
        case let .startsWithDot(alias):
            "alias \"\(alias)\" must not start with '.' (would be hidden in Finder and most shells)"
        case let .disallowedCharacter(alias, scalar):
            """
            alias "\(alias)" contains disallowed character \
            '\(scalar)' (allowed: ASCII letters, digits, '-', '_', '.')
            """
        case let .allDots(alias):
            "alias \"\(alias)\" must not consist only of dots (path traversal risk)"
        }
    }
}
