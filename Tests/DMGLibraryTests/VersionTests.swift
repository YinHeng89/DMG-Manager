import XCTest
@testable import DMGLibrary

final class VersionTests: XCTestCase {
    func testComparison() {
        XCTAssertEqual(VersionComparator.compare("1.0", "1.0"), .orderedSame)
        XCTAssertEqual(VersionComparator.compare("139.0.7258.76", "139.0.7258"), .orderedDescending)
        XCTAssertEqual(VersionComparator.compare("1.2.3", "1.10.0"), .orderedAscending)
        XCTAssertEqual(VersionComparator.compare("v2.0", "2.0.1"), .orderedAscending)
        XCTAssertEqual(VersionComparator.compare("1.0-beta", "1.0"), .orderedAscending)
    }
}
