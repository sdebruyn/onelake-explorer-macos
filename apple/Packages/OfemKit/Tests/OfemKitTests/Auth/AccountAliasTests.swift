import Testing
@testable import OfemKit

// MARK: - AccountAliasTests

/// Tests for ``AccountAlias`` and ``AccountAlias/validate(_:)``.
///
/// Each test mirrors a case from `internal/auth/account_test.go` so that
/// the Swift and Go validation rules stay in sync.
@Suite("AccountAlias")
struct AccountAliasTests {
    // MARK: - Valid aliases

    @Test("Simple alphanumeric alias is accepted")
    func simpleAlphanumericAlias() throws {
        let alias = try AccountAlias("work")
        #expect(alias.rawValue == "work")
        #expect(alias.description == "work")
    }

    @Test("Alias with dash and underscore is accepted")
    func aliasWithDashAndUnderscore() throws {
        let alias = try AccountAlias("client-a_2")
        #expect(alias.rawValue == "client-a_2")
    }

    @Test("Alias with dot in the middle is accepted")
    func aliasWithDotInMiddle() throws {
        let alias = try AccountAlias("contoso.work")
        #expect(alias.rawValue == "contoso.work")
    }

    @Test("Alias of exactly 32 characters is accepted")
    func aliasOfMaxLength() throws {
        let thirtyTwo = String(repeating: "a", count: 32)
        let alias = try AccountAlias(thirtyTwo)
        #expect(alias.rawValue.count == 32)
    }

    @Test("Single character alias is accepted")
    func singleCharacterAlias() throws {
        let alias = try AccountAlias("x")
        #expect(alias.rawValue == "x")
    }

    // MARK: - Invalid aliases: empty

    @Test("Empty alias is rejected")
    func emptyAliasRejected() {
        #expect(throws: AccountAliasError.self) {
            try AccountAlias("")
        }
    }

    // MARK: - Invalid aliases: too long

    @Test("Alias of 33 characters is rejected")
    func tooLongAliasRejected() {
        let thirtyThree = String(repeating: "a", count: 33)
        #expect(throws: AccountAliasError.self) {
            try AccountAlias(thirtyThree)
        }
    }

    // MARK: - Invalid aliases: bad first character

    @Test("Alias starting with dash is rejected")
    func aliasStartingWithDashRejected() {
        #expect(throws: AccountAliasError.self) {
            try AccountAlias("-bad")
        }
    }

    @Test("Alias starting with dot is rejected")
    func aliasStartingWithDotRejected() {
        #expect(throws: AccountAliasError.self) {
            try AccountAlias(".hidden")
        }
    }

    // MARK: - Invalid aliases: disallowed characters

    @Test("Alias with space is rejected")
    func aliasWithSpaceRejected() {
        #expect(throws: AccountAliasError.self) {
            try AccountAlias("my alias")
        }
    }

    @Test("Alias with slash is rejected")
    func aliasWithSlashRejected() {
        #expect(throws: AccountAliasError.self) {
            try AccountAlias("path/slash")
        }
    }

    @Test("Alias with non-ASCII character is rejected")
    func aliasWithNonASCIIRejected() {
        #expect(throws: AccountAliasError.self) {
            try AccountAlias("café")
        }
    }

    @Test("Alias with at sign is rejected")
    func aliasWithAtSignRejected() {
        #expect(throws: AccountAliasError.self) {
            try AccountAlias("sam@contoso")
        }
    }

    // MARK: - Invalid aliases: all-dots

    @Test("Single dot alias is rejected")
    func singleDotAliasRejected() {
        // Note: starts with dot, so caught by the leading-dot rule first.
        #expect(throws: AccountAliasError.self) {
            try AccountAlias(".")
        }
    }

    @Test("Double-dot alias is rejected")
    func doubleDotAliasRejected() {
        #expect(throws: AccountAliasError.self) {
            try AccountAlias("..")
        }
    }

    // MARK: - Hashable / Equatable

    @Test("Equal aliases hash to the same value")
    func hashableEquality() throws {
        let a1 = try AccountAlias("work")
        let a2 = try AccountAlias("work")
        #expect(a1 == a2)
        #expect(a1.hashValue == a2.hashValue)
    }

    @Test("Different aliases are not equal")
    func hashableInequality() throws {
        let a1 = try AccountAlias("work")
        let a2 = try AccountAlias("home")
        #expect(a1 != a2)
    }

    @Test("Alias can be used as a Set element")
    func aliasAsSetElement() throws {
        let a1 = try AccountAlias("work")
        let a2 = try AccountAlias("home")
        let a3 = try AccountAlias("work") // duplicate
        let set: Set<AccountAlias> = [a1, a2, a3]
        #expect(set.count == 2)
    }
}
