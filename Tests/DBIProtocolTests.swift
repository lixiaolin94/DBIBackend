import XCTest
@testable import DBI_Backend

/// 按脚本回放 Switch 发来的数据，记录电脑发出的数据
private final class ScriptedLink: DBILink {
    var incoming: [Data]
    var outgoing: [Data] = []
    init(_ incoming: [Data]) { self.incoming = incoming }

    func read(_ length: Int) throws -> Data {
        guard !incoming.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return incoming.removeFirst()
    }

    func write(_ data: Data) throws { outgoing.append(data) }
}

private func request(_ command: DBICommand, size: UInt32 = 0) -> Data {
    DBIHeader(.request, command, size: size).encoded
}

private func rangeRequest(name: String, offset: UInt64, length: UInt32) -> Data {
    var d = Data()
    d.appendLE(length)
    d.appendLE(offset)
    d.appendLE(UInt32(name.utf8.count))
    d.append(Data(name.utf8))
    return d
}

final class DBIProtocolTests: XCTestCase {
    private func tempFile(_ data: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testListThenRangeThenExit() throws {
        let content = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let url = try tempFile(content, name: "game.nsz")
        let ack = DBIHeader(.ack, .list, size: 0).encoded
        let range = rangeRequest(name: "game.nsz", offset: 1_000_000, length: 1_500_000)
        let link = ScriptedLink([
            request(.list),
            ack,
            request(.fileRange, size: UInt32(range.count)),
            range,
            DBIHeader(.ack, .fileRange, size: 0).encoded,
            request(.exit),
        ])
        var events: [DBIEvent] = []
        let session = DBISession(link: link, files: { [("game.nsz", url)] }) { events.append($0) }
        try session.run()

        // 列表：响应头 + 名字
        XCTAssertEqual(DBIHeader(link.outgoing[0]), DBIHeader(.response, .list, size: 9))
        XCTAssertEqual(link.outgoing[1], Data("game.nsz\n".utf8))
        // 文件段：ack 头 + 响应头 + 数据（按 1 MB 分块）
        XCTAssertEqual(DBIHeader(link.outgoing[2]), DBIHeader(.ack, .fileRange, size: UInt32(range.count)))
        XCTAssertEqual(DBIHeader(link.outgoing[3]), DBIHeader(.response, .fileRange, size: 1_500_000))
        let body = link.outgoing[4..<(link.outgoing.count - 1)].reduce(Data(), +)
        XCTAssertEqual(body, content.subdata(in: 1_000_000..<2_500_000))
        XCTAssertEqual(link.outgoing[4].count, DBISession.segment)
        // 退出
        XCTAssertEqual(DBIHeader(link.outgoing.last!), DBIHeader(.response, .exit, size: 0))
        guard case .sent("game.nsz", 1_000_000, 1_500_000) = events[1] else { return XCTFail("\(events)") }
        guard case .exit = events[2] else { return XCTFail("\(events)") }
    }

    func testEmptyListSendsNoBody() throws {
        let link = ScriptedLink([request(.list), request(.exit)])
        try DBISession(link: link, files: { [] }) { _ in }.run()
        XCTAssertEqual(link.outgoing.count, 2)
        XCTAssertEqual(DBIHeader(link.outgoing[0]), DBIHeader(.response, .list, size: 0))
    }

    func testUnknownFileThrows() throws {
        let range = rangeRequest(name: "gone.nsp", offset: 0, length: 16)
        let link = ScriptedLink([request(.fileRange, size: UInt32(range.count)), range, DBIHeader(.ack, .fileRange, size: 0).encoded])
        XCTAssertThrowsError(try DBISession(link: link, files: { [] }) { _ in }.run()) { error in
            guard case DBIError.unknownFile("gone.nsp") = error else { return XCTFail("\(error)") }
        }
    }

    func testGarbageIsSkipped() throws {
        let link = ScriptedLink([Data(repeating: 0, count: 16), request(.exit)])
        try DBISession(link: link, files: { [] }) { _ in }.run()
        XCTAssertEqual(link.outgoing.count, 1)
    }
}
