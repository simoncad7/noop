import XCTest
@testable import WhoopStore

final class PairedDeviceSourceKindTests: XCTestCase {
    func testLiveAppleWatchSourceKindExists() {
        XCTAssertEqual(SourceKind(rawValue: "liveAppleWatch"), .liveAppleWatch)
        XCTAssertTrue(SourceKind.allCases.contains(.liveAppleWatch))
    }

    func testSmartBand10SourceKindExists() {
        XCTAssertEqual(SourceKind(rawValue: "smartBand10"), .smartBand10)
        XCTAssertTrue(SourceKind.allCases.contains(.smartBand10))
    }
}
