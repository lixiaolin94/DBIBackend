import Foundation

// DBI「从 DBIbackend 安装游戏」的 USB 协议，和 DBI 官方的 dbibackend（Python）一致：
// https://github.com/rashevskyv/dbi/blob/main/dbibackend
//
// 每条消息先发 16 字节的头："DBI0" + 类型 + 命令 + 数据长度（都是小端 u32）。
// Switch 发请求，电脑回应；Switch 要哪个文件的哪一段，电脑就发哪一段（偏移是 64 位，没有 4 GB 限制）。

enum DBICommand: UInt32 {
    case exit = 0
    case listOld = 1
    case fileRange = 2
    case list = 3
}

enum DBIMessageType: UInt32 {
    case request = 0
    case response = 1
    case ack = 2
}

struct DBIHeader: Equatable {
    static let magic = Data("DBI0".utf8)
    static let length = 16

    var type: UInt32
    var command: UInt32
    var size: UInt32

    init(_ type: DBIMessageType, _ command: DBICommand, size: UInt32) {
        self.type = type.rawValue
        self.command = command.rawValue
        self.size = size
    }

    /// 不是 "DBI0" 开头的数据返回 nil（dbibackend 也是直接跳过）
    init?(_ data: Data) {
        guard data.count >= Self.length, data.prefix(4) == Self.magic else { return nil }
        type = data.u32(at: 4)
        command = data.u32(at: 8)
        size = data.u32(at: 12)
    }

    var encoded: Data {
        var d = Self.magic
        d.appendLE(type)
        d.appendLE(command)
        d.appendLE(size)
        return d
    }
}

/// 和 Switch 之间的一条双向通道。读写都是阻塞的，在会话线程上调用。
protocol DBILink: AnyObject {
    func read(_ length: Int) throws -> Data
    func write(_ data: Data) throws
}

enum DBIEvent: Sendable {
    /// Switch 要了文件列表
    case listed([String])
    /// 发完了某个文件的一段
    case sent(name: String, offset: UInt64, length: UInt32)
    /// Switch 退出了「从 DBIbackend 安装游戏」
    case exit
}

enum DBIError: LocalizedError {
    case unknownFile(String)
    case malformed(String)
    case fileChanged(String)

    var errorDescription: String? {
        switch self {
        case let .unknownFile(name): String(localized: "Switch 要的文件“\(name)”已经不在列表里了。")
        case let .malformed(what): String(localized: "Switch 发来的数据无法识别（\(what)）。")
        case let .fileChanged(name): String(localized: "“\(name)”在传输过程中被改动或删除了。")
        }
    }
}

/// 一次会话：从 Switch 进入「从 DBIbackend 安装游戏」开始，到它退出或者连接断开为止。
struct DBISession {
    /// 每次最多从文件里读多少再发（和 dbibackend 一样 1 MB）
    static let segment = 1 << 20

    let link: DBILink
    /// 当前可安装的文件：名字 → 本地路径。每次 Switch 要列表或要数据时都会重新取，所以中途加的文件也能看到。
    let files: () -> [(name: String, url: URL)]
    let onEvent: (DBIEvent) -> Void

    /// 阻塞运行，直到 Switch 发来退出（正常返回）或者读写出错（抛出）
    func run() throws {
        var cache: (name: String, handle: FileHandle)?
        defer { try? cache?.handle.close() }
        while true {
            guard let header = DBIHeader(try link.read(DBIHeader.length)) else { continue }
            switch DBICommand(rawValue: header.command) {
            case .list:
                try sendList()
            case .fileRange:
                try sendRange(requestSize: header.size, cache: &cache)
            case .exit:
                try link.write(DBIHeader(.response, .exit, size: 0).encoded)
                onEvent(.exit)
                return
            case .listOld, nil:
                continue   // dbibackend 也不处理
            }
        }
    }

    private func sendList() throws {
        let names = files().map(\.name)
        let list = Data(names.map { $0 + "\n" }.joined().utf8)
        try link.write(DBIHeader(.response, .list, size: UInt32(list.count)).encoded)
        if !list.isEmpty {
            _ = try link.read(DBIHeader.length)   // Switch 的 ack
            try link.write(list)
        }
        onEvent(.listed(names))
    }

    private func sendRange(requestSize: UInt32, cache: inout (name: String, handle: FileHandle)?) throws {
        try link.write(DBIHeader(.ack, .fileRange, size: requestSize).encoded)
        let request = try link.read(Int(requestSize))
        guard request.count >= 16 else { throw DBIError.malformed("文件段请求只有 \(request.count) 字节") }
        let length = request.u32(at: 0)
        let offset = request.u64(at: 4)
        let nameLength = Int(request.u32(at: 12))
        guard request.count >= 16 + nameLength else { throw DBIError.malformed("文件名长度 \(nameLength)") }
        let name = String(decoding: request.subdata(in: request.startIndex + 16 ..< request.startIndex + 16 + nameLength), as: UTF8.self)

        try link.write(DBIHeader(.response, .fileRange, size: length).encoded)
        _ = try link.read(DBIHeader.length)   // Switch 的 ack

        if cache?.name != name {
            try? cache?.handle.close()
            cache = nil
            guard let url = files().first(where: { $0.name == name })?.url else { throw DBIError.unknownFile(name) }
            cache = (name, try FileHandle(forReadingFrom: url))
        }
        let handle = cache!.handle
        try handle.seek(toOffset: offset)
        var left = Int(length)
        while left > 0 {
            let chunk = try handle.read(upToCount: min(left, Self.segment)) ?? Data()
            guard !chunk.isEmpty else { throw DBIError.fileChanged(name) }
            try link.write(chunk)
            left -= chunk.count
        }
        onEvent(.sent(name: name, offset: offset, length: length))
    }
}

extension Data {
    func u32(at offset: Int) -> UInt32 {
        var v: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { copyBytes(to: $0, from: startIndex + offset ..< startIndex + offset + 4) }
        return UInt32(littleEndian: v)
    }

    func u64(at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { copyBytes(to: $0, from: startIndex + offset ..< startIndex + offset + 8) }
        return UInt64(littleEndian: v)
    }

    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
