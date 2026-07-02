@testable import OfemKit
import Testing

// MARK: - Privacy.isGUID Tests

/// Tests for ``Privacy/isGUID(_:)`` — the single canonical GUID validator now
/// shared by the telemetry redaction path and `EntraAuthorityResolver` (R6:
/// the two used to disagree on edge inputs because `EntraAuthorityResolver`
/// carried its own private `NSRegularExpression`-backed copy).
@Suite("Privacy.isGUID")
struct PrivacyTests {
    // MARK: - Valid inputs

    @Test("Lowercase GUID is valid")
    func lowercaseGUID() {
        #expect(Privacy.isGUID("aaaabbbb-cccc-dddd-eeee-ffffffffffff"))
    }

    @Test("Uppercase GUID is valid")
    func uppercaseGUID() {
        #expect(Privacy.isGUID("AAAABBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"))
    }

    @Test("Mixed-case GUID is valid")
    func mixedCaseGUID() {
        #expect(Privacy.isGUID("AaBbCcDd-1234-5678-90aB-cDeF01234567"))
    }

    // MARK: - Invalid inputs

    @Test("Empty string is not a GUID")
    func emptyString() {
        #expect(!Privacy.isGUID(""))
    }

    @Test("Too-short string is not a GUID")
    func tooShort() {
        #expect(!Privacy.isGUID("aaaabbbb-cccc-dddd-eeee-fffffffffff"))
    }

    @Test("Wrong hyphen position is not a GUID")
    func wrongHyphenPosition() {
        #expect(!Privacy.isGUID("aaaabbb-ccccc-dddd-eeee-ffffffffffff"))
    }

    @Test("Non-hex character is not a GUID")
    func nonHexCharacter() {
        #expect(!Privacy.isGUID("gggggggg-cccc-dddd-eeee-ffffffffffff"))
    }

    /// R6 regression: the historical private regex in `EntraAuthorityResolver`
    /// anchored with `^...$`. In non-multiline mode `$` matches immediately
    /// before a single trailing line terminator, so a 36-char GUID followed by
    /// `"\n"` would have satisfied that regex while carrying an extra byte.
    /// `Privacy.isGUID`'s exact-length precheck (`s.utf8.count == 36`) rejects
    /// it outright — this pins the stricter behaviour now shared everywhere.
    @Test("Valid GUID with trailing newline is not a GUID (R6 tricky input)")
    func trailingNewlineIsRejected() {
        #expect(!Privacy.isGUID("aaaabbbb-cccc-dddd-eeee-ffffffffffff\n"))
    }

    @Test("Valid GUID with leading whitespace is not a GUID")
    func leadingWhitespaceIsRejected() {
        #expect(!Privacy.isGUID(" aaaabbbb-cccc-dddd-eeee-ffffffffffff"))
    }

    @Test("Braced GUID form is not a GUID")
    func bracedFormIsRejected() {
        #expect(!Privacy.isGUID("{aaaabbbb-cccc-dddd-eeee-ffffffffffff}"))
    }
}
