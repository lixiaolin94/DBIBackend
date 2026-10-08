import XCTest
@testable import DBI_Backend

final class CoverageTests: XCTestCase {
    func testHeaderTailAndRereadsCountOnce() {
        var c = Coverage()
        c.insert(0..<16)                 // 文件头
        c.insert(900..<1000)             // 文件尾
        c.insert(0..<100)                // 重读开头
        XCTAssertEqual(c.total, 200)
        c.insert(100..<900)              // 中间按顺序读完
        XCTAssertEqual(c.ranges, [0..<1000])
        XCTAssertEqual(c.total, 1000)
    }

    func testDisjointRangesStaySorted() {
        var c = Coverage()
        c.insert(50..<60)
        c.insert(10..<20)
        c.insert(30..<40)
        XCTAssertEqual(c.ranges, [10..<20, 30..<40, 50..<60])
        c.insert(15..<35)
        XCTAssertEqual(c.ranges, [10..<40, 50..<60])
        XCTAssertEqual(c.total, 40)
    }
}
