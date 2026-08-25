import XCTest
@testable import FanControlCore

final class FanControlCoreTests: XCTestCase {
    func testPackageVersion() {
        XCTAssertEqual(FanControlCoreVersion.string, "0.1.0")
    }
}
