import Testing
@testable import OfemKit

@Test func packageVersionIsExposed() {
    #expect(OfemKit.version == "0.1.0-dev")
}
