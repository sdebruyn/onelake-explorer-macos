// XPCErrorBridgingTests.swift
// Tests for the XPC error-bridging layer (xpc-03).
//
// Custom Swift error types returned over XPC may not survive NSSecureCoding
// across the process boundary — a non-NSError Swift enum arrives as a generic
// NSError that loses the original case and errorDescription. XPCError.swift
// defines a stable NSError domain and typed codes so the host can distinguish
// validation failures from transport failures.

import Foundation
import XCTest

final class XPCErrorBridgingTests: XCTestCase {

    // MARK: - Domain constant

    func testOfemXPCErrorDomainValue() {
        XCTAssertEqual(OfemXPCErrorDomain, "dev.debruyn.ofem.xpc")
    }

    // MARK: - NSError factory

    func testOfemXPCErrorHasCorrectDomain() {
        let err = NSError.ofemXPC(code: .setConfigUnknownKey, message: "unknown key 'foo'")
        XCTAssertEqual(err.domain, OfemXPCErrorDomain)
    }

    func testOfemXPCErrorHasCorrectCode() {
        let err = NSError.ofemXPC(code: .setConfigInvalidValue, message: "bad value")
        XCTAssertEqual(err.code, OfemXPCErrorCode.setConfigInvalidValue.rawValue)
    }

    func testOfemXPCErrorLocalizedDescriptionMatchesMessage() {
        let message = "setConfig: unknown key 'cache.nonexistent'"
        let err = NSError.ofemXPC(code: .setConfigUnknownKey, message: message)
        XCTAssertEqual(err.localizedDescription, message)
    }

    func testOfemXPCErrorUserInfoContainsOfemMessage() {
        let message = "setConfig: invalid value 'x' for key 'telemetry'"
        let err = NSError.ofemXPC(code: .setConfigInvalidValue, message: message)
        XCTAssertEqual(err.userInfo["OfemMessage"] as? String, message)
    }

    func testInternalErrorCode() {
        let err = NSError.ofemXPC(code: .internalError, message: "unexpected failure")
        XCTAssertEqual(err.code, OfemXPCErrorCode.internalError.rawValue)
        XCTAssertEqual(err.domain, OfemXPCErrorDomain)
    }

    // MARK: - Error code raw values (stable across builds)

    func testErrorCodeRawValuesAreStable() {
        // These must never change — the host switch-cases on them.
        XCTAssertEqual(OfemXPCErrorCode.setConfigUnknownKey.rawValue,   100)
        XCTAssertEqual(OfemXPCErrorCode.setConfigInvalidValue.rawValue, 101)
        XCTAssertEqual(OfemXPCErrorCode.internalError.rawValue,         900)
    }

    // MARK: - NSError.ofemXPC(for:) bridging

    func testBridgingAlreadyBridgedErrorIsNoop() {
        let original = NSError.ofemXPC(code: .setConfigUnknownKey, message: "already bridged")
        let bridged  = NSError.ofemXPC(for: original)
        XCTAssertEqual(bridged.domain, OfemXPCErrorDomain)
        XCTAssertEqual(bridged.code,   OfemXPCErrorCode.setConfigUnknownKey.rawValue)
        XCTAssertEqual(bridged.localizedDescription, "already bridged")
    }

    func testBridgingArbitraryNSErrorProducesInternalError() {
        let nsErr = NSError(domain: NSCocoaErrorDomain, code: 100,
                            userInfo: [NSLocalizedDescriptionKey: "some cocoa error"])
        let bridged = NSError.ofemXPC(for: nsErr)
        XCTAssertEqual(bridged.domain, OfemXPCErrorDomain)
        XCTAssertEqual(bridged.code, OfemXPCErrorCode.internalError.rawValue)
    }

    func testBridgingPreservesLocalizedDescription() {
        struct SomeError: Error, LocalizedError {
            var errorDescription: String? { "some error description" }
        }
        let bridged = NSError.ofemXPC(for: SomeError())
        XCTAssertTrue(bridged.localizedDescription.contains("some error description"))
    }

    // MARK: - Round-trip through NSKeyedArchiver (simulates XPC transport)

    func testXPCErrorSurvivesNSSecureCodingRoundTrip() throws {
        let original = NSError.ofemXPC(code: .setConfigInvalidValue,
                                        message: "invalid value '255' for key 'cache.max_size_gb'")

        // NSError conforms to NSSecureCoding natively; archive → unarchive
        // simulates what XPC does when it serialises the Error? reply param.
        let data = try NSKeyedArchiver.archivedData(withRootObject: original,
                                                    requiringSecureCoding: true)
        let decoded = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data),
            "NSError did not survive NSKeyedArchiver round-trip"
        )

        XCTAssertEqual(decoded.domain, OfemXPCErrorDomain)
        XCTAssertEqual(decoded.code,   OfemXPCErrorCode.setConfigInvalidValue.rawValue)
        XCTAssertEqual(decoded.localizedDescription,
                       "invalid value '255' for key 'cache.max_size_gb'")
    }

    func testDistinguishUnknownKeyFromInvalidValue() throws {
        // Verify the host can switch on code after a round-trip.
        let errors: [(OfemXPCErrorCode, String)] = [
            (.setConfigUnknownKey,   "unknown key 'foo'"),
            (.setConfigInvalidValue, "invalid value 'bar' for key 'telemetry'")
        ]
        for (code, msg) in errors {
            let original = NSError.ofemXPC(code: code, message: msg)
            let data = try NSKeyedArchiver.archivedData(withRootObject: original,
                                                        requiringSecureCoding: true)
            let decoded = try XCTUnwrap(
                NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data)
            )
            XCTAssertEqual(OfemXPCErrorCode(rawValue: decoded.code), code,
                           "code \(code) did not survive round-trip")
        }
    }
}
