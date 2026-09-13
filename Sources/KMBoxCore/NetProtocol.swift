import Foundation
import Darwin

public enum KMError: Error, LocalizedError, Equatable {
    case invalid(String)
    case io(String)
    case disconnected
    case timeout(String)
    case uncertain(String)
    case device(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .io(let s), .device(let s), .conflict(let s): return s
        case .disconnected: return "尚未连接设备。"
        case .timeout(let s): return "等待设备超时：\(s)"
        case .uncertain(let s): return "\(s)；设备是否已执行无法确定。已停止后续动作，请点击全部释放；若已断开，重新连接后再全部释放。"
        }
    }
}

public struct NetConfiguration: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var uuid: UInt32
    public var localAddress: String?
    public var timeout: TimeInterval

    public init(host: String, port: String, uuid: String, localAddress: String? = nil,
                timeout: TimeInterval = 1.0) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else {
            throw KMError.invalid("请输入盒子屏幕上的 IPv4 地址。")
        }
        guard let number = UInt16(port), number > 0 else {
            throw KMError.invalid("端口必须是 1–65535 的整数。")
        }
        var hex = uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard !hex.isEmpty, hex.count <= 8,
              hex.allSatisfy({ $0.isASCII && $0.isHexDigit }), let id = UInt32(hex, radix: 16) else {
            throw KMError.invalid("UUID 应为最多 8 位十六进制数字，使用盒子屏幕上的值。")
        }
        if let localAddress, !localAddress.isEmpty {
            guard inet_pton(AF_INET, localAddress, &address) == 1 else {
                throw KMError.invalid("本机接口地址不是有效的 IPv4 地址。")
            }
        }
        guard timeout.isFinite, (0.05...10).contains(timeout) else {
            throw KMError.invalid("通信超时范围为 0.05–10 秒。")
        }
        self.host = host; self.port = number; self.uuid = id
        self.localAddress = localAddress?.isEmpty == false ? localAddress : nil
        self.timeout = timeout
    }
}

public enum NetCommand: UInt32, Sendable {
    case connect = 0xaf3c2828
    case move = 0xaede7345
    case automaticMove = 0xaede7346
    case bezierMove = 0xa238455a
    case left = 0x9823ae8d
    case middle = 0x97a3ae8d
    case right = 0x238d8212
    case wheel = 0xffeead38
    case keyboard = 0x123c2c2f
    case monitor = 0x27388020
    case mask = 0x23234343
    case unmask = 0x23344343
    case setNetwork = 0x1d3d3323
    case setVIDPID = 0xffed3232
    case curve = 0xbbcdddac
    case peripheral = 0xadce1238
    case bypass = 0x21223334
    case reboot = 0xaa8855aa
}

public struct PacketHeader: Sendable, Equatable {
    public let uuid: UInt32
    public let random: UInt32
    public let sequence: UInt32
    public let command: UInt32

    public init(uuid: UInt32, random: UInt32, sequence: UInt32, command: UInt32) {
        self.uuid = uuid; self.random = random; self.sequence = sequence; self.command = command
    }

    public init(data: Data) throws {
        guard data.count >= 16 else { throw KMError.invalid("应答不足 16 字节。") }
        let bytes = Array(data.prefix(16))
        func word(_ index: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | (UInt32(bytes[index + $1]) << (8 * $1)) }
        }
        self.init(uuid: word(0), random: word(4), sequence: word(8), command: word(12))
    }

    public var data: Data {
        var output = Data()
        for value in [uuid, random, sequence, command] { output.appendLE(value) }
        return output
    }
}

public struct MouseState: Sendable, Equatable {
    public var buttons: Int32 = 0
    public init() {}
    public func payload(x: Int32 = 0, y: Int32 = 0, wheel: Int32 = 0, controls: NetBezierControls? = nil) -> Data {
        var output = Data()
        let points: [Int32] = controls.map { [$0.x1, $0.y1, $0.x2, $0.y2] } ?? [0, 0, 0, 0]
        for value in [buttons, x, y, wheel] + points + Array(repeating: Int32(0), count: 6) {
            output.appendLE(UInt32(bitPattern: value))
        }
        return output
    }
}

public struct KeyboardState: Sendable, Equatable {
    public private(set) var modifiers: UInt8 = 0
    public private(set) var keys: [UInt8] = []
    public init() {}

    public mutating func set(_ key: UInt8, down: Bool) throws {
        guard key >= 4, key <= 0xe7 else { throw KMError.invalid("无效的 USB HID 按键码。") }
        if (0xe0...0xe7).contains(key) {
            let bit = UInt8(1) << (key - 0xe0)
            if down { modifiers |= bit } else { modifiers &= ~bit }
        } else if down {
            if !keys.contains(key) {
                guard keys.count < 10 else { throw KMError.invalid("最多同时按下 10 个普通按键。") }
                keys.append(key)
            }
        } else { keys.removeAll { $0 == key } }
    }

    public var payload: Data { Data([modifiers, 0] + keys + Array(repeating: 0, count: 10 - keys.count)) }
}

extension Data {
    mutating func appendLE(_ value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    public var hexadecimal: String { map { String(format: "%02x", $0) }.joined() }
    public init?(hexadecimal: String) {
        let chars = Array(hexadecimal)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}

public struct NetworkInterface: Identifiable, Sendable, Equatable {
    public var id: String { "\(name):\(address)" }
    public let name: String
    public let address: String
    public static func available() -> [NetworkInterface] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [NetworkInterface] = []
        var cursor = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (item.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer,
                           socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(NetworkInterface(name: String(cString: item.pointee.ifa_name), address: String(cString: buffer)))
            }
        }
        return result.sorted { $0.name < $1.name }
    }
}
