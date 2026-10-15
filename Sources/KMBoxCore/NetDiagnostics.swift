import Foundation
import Darwin

public struct NetNetworkSettings: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    var parameter: UInt32 { host.split(separator: ".").enumerated().reduce(0) { $0 | UInt32($1.element)! << ($1.offset * 8) } }
    var payload: Data { Data([UInt8(port >> 8), UInt8(truncatingIfNeeded: port)]) }

    public init(host: String, port: String) throws {
        let value = try NetConfiguration(host: host, port: port, uuid: "0")
        let first = Int(value.host.split(separator: ".")[0])!
        guard (1...223).contains(first), first != 127 else { throw KMError.invalid("盒子地址需要可用的单播 IPv4，不能是未指定、回环或组播地址。") }
        self.host = value.host; self.port = value.port
    }
}

/// Fixed indices of the Net host 20260904 combobox, not a device-discovered catalog.
/// NB has additional algorithms; its identifiers and readback are not established by this enum.
public enum NetCurve: Int, CaseIterable, Identifiable, Sendable {
    case bezier = 0, arm, realtimeBezier, realtimeArm
    public var id: Int { rawValue }
    public var name: String {
        switch self {
        case .bezier: return "Bezier"
        case .arm: return "Arm"
        case .realtimeBezier: return "RT-Bezier"
        case .realtimeArm: return "RT-Arm"
        }
    }
}

public struct NetCurveSettings: Sendable, Equatable {
    public let enabled: Bool
    public let curve: NetCurve
    public let strength: Int
    var parameter: UInt32 { enabled ? UInt32(curve.rawValue) << 24 | UInt32(strength) : 0 }
    public init(enabled: Bool, curve: NetCurve, strength: Int) throws {
        guard (0...100).contains(strength) else { throw KMError.invalid("Net 兼容曲线值范围为 0–100。") }
        self.enabled = enabled; self.curve = curve; self.strength = strength
    }
}

public struct NetParsingModes: Sendable, Equatable {
    public let mouse: UInt8
    public let keyboard: UInt8
    public init(mouse: Int, keyboard: Int) throws {
        guard ((0...32).contains(mouse) || mouse == 255),
              ((0...32).contains(keyboard) || keyboard == 255), mouse != 255 || keyboard != 255 else {
            throw KMError.invalid("解析模式取值为 0–32，255 表示无此类设备；两项不能同时为 255。")
        }
        self.mouse = UInt8(mouse); self.keyboard = UInt8(keyboard)
    }
}

public struct NetPeripheralInfo: Sendable, Equatable, Codable {
    public let vendorID: UInt16
    public let productID: UInt16
    public let hidID: UInt16
    public let deviceID: UInt16
    public let mouseMode: UInt8
    public let keyboardMode: UInt8
    public let raw: Data
    public var isEmpty: Bool { vendorID == 0 && productID == 0 && hidID == 0 && deviceID == 0 }
    public init(data: Data) throws {
        guard data.count >= 10 else { throw KMError.device("外设信息应答不足 10 字节，当前固件可能不支持此查询。") }
        let b = Array(data.prefix(10))
        func word(_ index: Int) -> UInt16 { UInt16(b[index]) | UInt16(b[index + 1]) << 8 }
        vendorID = word(0); productID = word(2); hidID = word(4); deviceID = word(6)
        mouseMode = b[8]; keyboardMode = b[9]; raw = Data(b)
    }
    func payload(with modes: NetParsingModes) -> Data { raw.prefix(8) + Data([modes.mouse, modes.keyboard]) }
}

/// Decodes the 20-byte mouse/keyboard prefix consumed by the Net host.
/// Additional bytes are not interpreted; NetMonitorRecord retains the full datagram.
public struct NetMonitorFrame: Sendable, Equatable, Codable {
    public let mouseReportID: UInt8
    public let buttons: UInt8
    public let x: Int16
    public let y: Int16
    public let wheel: Int16
    public let keyboardReportID: UInt8
    public let modifiers: UInt8
    public let keys: [UInt8]
    public init(data: Data) throws {
        guard data.count >= 20 else { throw KMError.device("监控报文不足 20 字节：\(data.count)。") }
        let b = Array(data.prefix(20))
        func signed(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8) }
        mouseReportID = b[0]; buttons = b[1]; x = signed(2); y = signed(4); wheel = signed(6)
        keyboardReportID = b[8]; modifiers = b[9]; keys = b[10..<20].filter { $0 != 0 }
    }
}

public struct NetMonitorBatch: Sendable {
    public let records: [NetMonitorRecord]
    public var frames: [NetMonitorFrame] { records.compactMap(\.frame) }
    /// Cumulative expected-device datagrams, including undecodable reports.
    public let received: UInt64
    /// Cumulative expected-device reports shorter than the known 20-byte prefix.
    public let undecodable: UInt64
    /// Cumulative datagrams rejected by the expected-device IPv4 filter.
    public let foreignSource: UInt64
    /// Cumulative accepted reports with uninterpreted bytes after the known prefix.
    public let extended: UInt64
    /// Cumulative decoded reports; includes extended-prefix reports.
    public let accepted: UInt64
    /// Cumulative undecodable plus foreign-source datagrams, retained for existing consumers.
    public let rejected: UInt64
    public let lastRejectedLength: Int?
    /// Most recent expected-device datagram; foreign-source traffic does not update these.
    public let lastReceivedAt: Date?
    public let lastReceivedLength: Int?
}

/// Confined to NetClient. Bind before enabling device reports; never reuse another receiver's port.
final class NetMonitorReceiver {
    private var fd: Int32 = -1
    private let peerAddress: in_addr_t
    private let host: String
    private let sessionID = UUID()
    private var sequence: UInt64 = 0
    let port: UInt16
    let localAddress: String
    private var accepted: UInt64 = 0
    private var rejected: UInt64 = 0
    private var received: UInt64 = 0
    private var undecodable: UInt64 = 0
    private var foreignSource: UInt64 = 0
    private var extended: UInt64 = 0
    private var lastRejectedLength: Int?
    private var lastReceivedAt: Date?
    private var lastReceivedLength: Int?

    init(local: sockaddr_in, host: String, port: UInt16) throws {
        guard (1024...49151).contains(port) else { throw KMError.invalid("监控端口范围为 1024–49151。") }
        self.port = port; self.host = host
        peerAddress = try socketAddress(host, port: 0).sin_addr.s_addr
        var localIPv4 = local.sin_addr
        var addressText = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let converted = addressText.withUnsafeMutableBufferPointer {
            inet_ntop(AF_INET, &localIPv4, $0.baseAddress, socklen_t($0.count)) != nil
        }
        guard converted else { throw socketError("格式化监控本机地址") }
        localAddress = String(cString: addressText)
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw socketError("创建监控套接字") }
        fd = descriptor
        var address = local; address.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw socketError("绑定监控端口 \(port)") }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw socketError("设置监控非阻塞模式") }
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }

    func read() throws -> NetMonitorBatch {
        var records: [NetMonitorRecord] = []
        // Full UDP payload capacity preserves unexpected firmware formats without truncation.
        var bytes = [UInt8](repeating: 0, count: 65_535)
        for _ in 0..<512 {
            var peer = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &bytes, bytes.count, 0, $0, &length) }
            }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                if errno == EINTR { continue }
                throw socketError("读取监控报文")
            }
            let receivedAt = Date(), receivedTick = DispatchTime.now().uptimeNanoseconds
            guard peer.sin_addr.s_addr == peerAddress else { rejected &+= 1; foreignSource &+= 1; continue }
            received &+= 1; lastReceivedAt = receivedAt; lastReceivedLength = count
            sequence += 1
            let record = NetMonitorRecord(data: Data(bytes.prefix(count)), sessionID: sessionID, sequence: sequence,
                                          receivedAt: receivedAt, monotonicNanoseconds: receivedTick,
                                          sourceIPv4: host, sourcePort: UInt16(bigEndian: peer.sin_port), listenPort: port)
            records.append(record)
            if record.frame != nil {
                accepted &+= 1
                if count > 20 { extended &+= 1 }
            } else { rejected &+= 1; undecodable &+= 1; lastRejectedLength = count }
        }
        return NetMonitorBatch(records: records, received: received, undecodable: undecodable,
                               foreignSource: foreignSource, extended: extended, accepted: accepted,
                               rejected: rejected, lastRejectedLength: lastRejectedLength,
                               lastReceivedAt: lastReceivedAt, lastReceivedLength: lastReceivedLength)
    }
}
