import XCTest
@testable import InternalDisplayOffCore

final class DisplayIdentityTests: XCTestCase {
    func testStorageKeyIncludesDisplayType() {
        let builtin = DisplayIdentity(uuid: "ABC-123", isBuiltin: true)
        let external = DisplayIdentity(uuid: "ABC-123", isBuiltin: false)

        XCTAssertEqual(builtin.storageKey, "builtin:abc-123")
        XCTAssertEqual(external.storageKey, "external:abc-123")
        XCTAssertNotEqual(builtin, external)
    }

    func testIdentityRoundTripsThroughJSON() throws {
        let original = DisplayIdentity(uuid: "a1b2-c3d4", isBuiltin: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DisplayIdentity.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.storageKey, "external:a1b2-c3d4")
    }
}
