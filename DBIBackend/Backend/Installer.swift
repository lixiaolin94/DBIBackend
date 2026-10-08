import Foundation
import IOKit
import os

private let log = Logger(subsystem: "work.xiaolin.DBIBackend", category: "installer")

/// 待安装的游戏列表 + 和 Switch 的连接。界面只读这里的状态，变化时发 `didChange`。
@MainActor
final class Installer {
    static let didChange = Notification.Name("InstallerDidChange")
    static let shared = Installer()

    /// DBI 能装的格式
    static let fileExtensions: Set<String> = ["nsp", "nsz", "xci", "xcz"]

    enum Connection: Equatable {
        /// 没有 Switch 处于「从 DBIbackend 安装游戏」
        case waiting
        case connected
        /// 设备在，但打不开或者会话出错
        case failed(String)
    }

    final class Item {
        enum State { case ready, sending, sent, interrupted }

        let id = UUID()
        let url: URL
        /// 发给 Switch 的名字（列表里重名时会加编号）
        let name: String
        let size: UInt64
        fileprivate(set) var state: State = .ready
        /// 已经发过的区间
        fileprivate(set) var coverage = Coverage()
        /// 累计发送的字节（含重读），用来算速度
        fileprivate(set) var bytesSent: UInt64 = 0
        /// 最近几秒的（时间, 累计字节）采样，用来算实时速度
        fileprivate var samples: [(time: Date, bytes: UInt64)] = []

        init(url: URL, name: String, size: UInt64) {
            self.url = url
            self.name = name
            self.size = size
        }

        /// 已经发给 Switch 的字节（不重复计算）
        var covered: UInt64 { coverage.total }

        /// 实时速度的统计窗口
        static let speedWindow: TimeInterval = 3

        /// 最近 3 秒的实时速度（字节/秒）。Switch 停下来不要数据时会逐渐降到 0；不在发送时为 nil。
        func bytesPerSecond(at now: Date = Date()) -> Double? {
            guard state == .sending, let first = samples.first, let last = samples.last else { return nil }
            let elapsed = now.timeIntervalSince(first.time)
            guard elapsed > 0.5 else { return nil }   // 刚开始，样本太少
            return Double(last.bytes - first.bytes) / max(elapsed, 1)
        }

        fileprivate func record(_ length: UInt64, at now: Date) {
            bytesSent += length
            samples.append((now, bytesSent))
            // 保留窗口起点之前的最后一个样本，作为这段时间的基准
            while samples.count > 2, now.timeIntervalSince(samples[1].time) >= Self.speedWindow { samples.removeFirst() }
        }
    }

    private(set) var connection: Connection = .waiting
    private(set) var items: [Item] = []
    /// 连上 Switch 时调用（用来把窗口拿到前面）
    var onConnect: (() -> Void)?

    var isSending: Bool { items.contains { $0.state == .sending } }

    private let catalog = Catalog()
    private var link: USBLink?
    private var notifyPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var changePending = false

    // MARK: 文件列表

    /// 加入文件；文件夹会展开成里面能装的文件。返回实际加入的个数。
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var added = 0
        for url in Self.installableFiles(in: urls) where !items.contains(where: { $0.url == url }) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            items.append(Item(url: url, name: uniqueName(for: url.lastPathComponent), size: size))
            added += 1
        }
        if added > 0 { syncCatalog() }
        return added
    }

    /// 移除；正在发送的不移除（Switch 还在读它）
    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) && $0.state != .sending }
        syncCatalog()
    }

    func removeFinished() {
        items.removeAll { $0.state == .sent }
        syncCatalog()
    }

    static func installableFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                let found = (walker?.allObjects as? [URL] ?? []).filter { fileExtensions.contains($0.pathExtension.lowercased()) }
                result += found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if fileExtensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }

    /// Switch 按名字要文件，所以名字必须唯一：重名时在扩展名前加编号
    private func uniqueName(for name: String) -> String {
        let taken = Set(items.map(\.name))
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for i in 2... {
            let candidate = "\(base) (\(i)).\(ext)"
            if !taken.contains(candidate) { return candidate }
        }
        return name
    }

    private func syncCatalog() {
        catalog.set(items.map { ($0.name, $0.url) })
        notifyChange()
    }

    // MARK: 连接

    /// 开始监听 Switch。已经插着的会立刻连上。
    func start() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, USBLink.matchingDictionary(), { refcon, iterator in
            guard let refcon else { return }
            let installer = Unmanaged<Installer>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { installer.devicesAppeared(iterator) }
        }, refcon, &matchIterator)
        if result == KERN_SUCCESS {
            devicesAppeared(matchIterator)   // 取走已有的匹配，同时启用通知
        } else {
            log.error("IOServiceAddMatchingNotification failed: \(result)")
        }
    }

    /// 出错之后手动重试（设备一直插着，不会再收到"出现"通知）
    func retry() {
        guard link == nil else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, USBLink.matchingDictionary())
        guard service != 0 else {
            connection = .waiting
            notifyChange()
            return
        }
        defer { IOObjectRelease(service) }
        connect(service)
    }

    /// 退出前调用：中止会话，Switch 那边会显示连接断开
    func stop() {
        link?.close()
    }

    private func devicesAppeared(_ iterator: io_iterator_t) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            connect(service)
            IOObjectRelease(service)
        }
    }

    private func connect(_ service: io_service_t) {
        guard link == nil else { return }
        let link: USBLink
        do {
            link = try USBLink(service: service)
        } catch {
            log.error("open failed: \(String(describing: error), privacy: .public)")
            connection = .failed(String(localized: "无法打开 Switch 的 USB 接口：\(error.localizedDescription)"))
            notifyChange()
            return
        }
        self.link = link
        connection = .connected
        log.info("connected")
        notifyChange()
        onConnect?()

        let catalog = catalog
        let thread = Thread { [weak self] in
            // 用主队列而不是 Task：进度事件必须按顺序到达
            let session = DBISession(link: link, files: { catalog.snapshot() }) { event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
            }
            let failure: (any Error)?
            do { try session.run(); failure = nil } catch { failure = error }
            let message = failure.map { String(describing: $0) }
            let protocolError = (failure as? DBIError)?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.sessionEnded(link, message: message, protocolError: protocolError) }
            }
        }
        thread.name = "DBI session"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func handle(_ event: DBIEvent) {
        switch event {
        case let .listed(names):
            log.info("listed \(names.count) files")
        case let .sent(name, offset, length):
            guard let item = items.first(where: { $0.name == name }) else { return }
            let now = Date()
            for other in items where other !== item && other.state == .sending {
                other.state = other.covered >= other.size ? .sent : .interrupted
            }
            if item.state != .sending {
                item.state = .sending
                item.coverage = Coverage()
                item.bytesSent = 0
                item.samples = [(now, 0)]
            }
            item.coverage.insert(offset ..< offset + UInt64(length))
            item.record(UInt64(length), at: now)
            if item.covered >= item.size { item.state = .sent }
        case .exit:
            log.info("switch exited")
        }
        notifyChange()
    }

    private func sessionEnded(_ ended: USBLink, message: String?, protocolError: String?) {
        ended.close()
        guard link === ended else { return }
        link = nil
        for item in items where item.state == .sending {
            item.state = item.covered >= item.size ? .sent : .interrupted
        }
        if let message { log.info("session ended: \(message, privacy: .public)") }
        // USB 读写出错多半是拔线或 Switch 退出了这个模式，回到等待；协议层的错误才算失败
        connection = protocolError.map { .failed($0) } ?? .waiting
        notifyChange()
    }

    /// 发送进度很密（每 1 MB 一次），合并成最多每 0.2 秒通知一次界面
    private func notifyChange() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changePending = false
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        }
    }
}

/// 会话线程读、主线程写的文件列表
private final class Catalog: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [(name: String, url: URL)] = []

    func set(_ files: [(name: String, url: URL)]) {
        lock.withLock { self.files = files }
    }

    func snapshot() -> [(name: String, url: URL)] {
        lock.withLock { files }
    }
}
