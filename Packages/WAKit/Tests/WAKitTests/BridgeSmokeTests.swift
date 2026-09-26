import Testing
@testable import WAKit

@Test func bridgeLinks() {
    #expect(WAKit.bridgeVersion().hasPrefix("wa-bridge"))
}
