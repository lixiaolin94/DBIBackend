import Foundation
import IOUSBHost

/// DBI「从 DBIbackend 安装游戏」时的 USB 接口：Switch 换成 VID 0x057E / PID 0x3000、名字 "DBI"，
/// 只有一个厂商自定义接口（class 0xFF），端点 0x01 发、0x81 收。
/// macOS 的 ptpcamerad 只认 PTP/MTP 设备，不会占这个接口，所以可以直接打开（2026-10-08 实测）。
final class USBLink: DBILink, @unchecked Sendable {
    static let vendorID = 0x057E
    static let productID = 0x3000

    /// IOKit 要求按 VID/PID 匹配接口时同时给出接口号和配置号，否则匹配不到
    static func matchingDictionary() -> CFMutableDictionary {
        IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: vendorID as NSNumber, productID: productID as NSNumber, bcdDevice: nil,
            interfaceNumber: 0, configurationValue: 1, interfaceClass: nil, interfaceSubclass: nil,
            interfaceProtocol: nil, speed: nil, productIDArray: nil
        ).takeRetainedValue()
    }

    private let interface: IOUSBHostInterface
    private let outPipe: IOUSBHostPipe
    private let inPipe: IOUSBHostPipe

    init(service: io_service_t) throws {
        interface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        do {
            outPipe = try interface.copyPipe(withAddress: 0x01)
            inPipe = try interface.copyPipe(withAddress: 0x81)
        } catch {
            interface.destroy()
            throw error
        }
    }

    func read(_ length: Int) throws -> Data {
        guard let buffer = NSMutableData(length: length) else { throw CocoaError(.fileReadUnknown) }
        var transferred = 0
        // 超时 0 表示一直等：Switch 那边可能停在列表界面很久不发请求
        try inPipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: 0)
        return Data(bytes: buffer.bytes, count: transferred)
    }

    func write(_ data: Data) throws {
        let buffer = NSMutableData(data: data)
        var transferred = 0
        try outPipe.__sendIORequest(with: buffer, bytesTransferred: &transferred, completionTimeout: 0)
    }

    /// 中止进行中的读写并释放接口。会话线程里阻塞着的读写会立刻抛错返回。
    func close() {
        interface.destroy()
    }
}
