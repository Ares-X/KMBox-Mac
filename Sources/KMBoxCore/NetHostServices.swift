import Foundation
import Darwin

public struct NetPingResult: Sendable, Codable {
    public let reached: Bool
    public let milliseconds: Double?
    public let output: String
}

public enum NetHostDiagnostics {
    /// ICMP does not create a Net control session or replace another controller.
    public static func ping(host: String, localAddress: String = "") async throws -> NetPingResult {
        _ = try socketAddress(host, port: 0)
        var arguments = ["-n", "-c", "1", "-W", "1000", "-t", "2"]
        if !localAddress.isEmpty { _ = try socketAddress(localAddress, port: 0); arguments += ["-S", localAddress] }
        arguments.append(host)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping"); process.arguments = arguments
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = pipe; process.standardError = pipe
        try Task.checkCancellation()
        try process.run()
        do {
            while process.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let milliseconds = output.range(of: #"time[=<]([0-9.]+)"#, options: .regularExpression)
            .flatMap { Double(output[$0].dropFirst(5)) }
        return NetPingResult(reached: process.terminationStatus == 0, milliseconds: milliseconds, output: output)
    }

    /// Original host's mislabeled "curve test": UDP 1752, magic at offsets 4 and 12.
    public static func chipID(host: String, localAddress: String = "", port: UInt16 = 1752,
                              timeout: TimeInterval = 1) async throws -> NetChipID {
        let socket = try HostServiceSocket(type: SOCK_DGRAM, local: localAddress, timeout: timeout)
        try await socket.connect(host: host, port: port)
        try await socket.send(NetChipID.request)
        return try NetChipID(data: await socket.receive(count: 2048, exact: false))
    }
}

public struct NetChipID: Sendable, Codable, Equatable {
    public let words: [UInt32]
    public let raw: Data
    public var text: String { words.map { String(format: "%08X", $0) }.joined(separator: "-") }
    static var request: Data {
        var data = Data(repeating: 0, count: 1024)
        for offset in [4, 12] { data.replaceSubrange(offset..<offset + 4, with: [0xba, 0xba, 0xfe, 0xef]) }
        return data
    }
    public init(data: Data) throws {
        guard data.count >= 28 else { throw KMError.device("芯片 ID 应答不足 28 字节。") }
        raw = data; words = [16, 20, 24].map { data.hostWord(at: $0) }
        guard words.contains(where: { $0 != 0 }) else { throw KMError.device("芯片 ID 应答全零，尚不能确认此固件支持查询。") }
    }
}

public struct NetAdaptation: Sendable, Equatable {
    public let peripheral: NetPeripheralInfo
    public let modes: NetParsingModes
    public let successes: UInt32
    public let failures: UInt32
    public let raw: Data
    public init(data: Data, peripheral: NetPeripheralInfo) throws {
        guard data.count == 40 else { throw KMError.device("厂商适配应答需要 40 字节。") }
        let status = data.hostWord(at: 28)
        guard status == 1 else {
            throw KMError.device(status == 3 ? "厂商数据库未找到该外设的适配方案。" : "厂商适配返回未识别状态 \(status)。")
        }
        // Windows reads the low byte of each 32-bit mode field.
        modes = try NetParsingModes(mouse: Int(data[20]), keyboard: Int(data[24]))
        self.peripheral = peripheral; successes = data.hostWord(at: 32); failures = data.hostWord(at: 36); raw = data
    }
}

public enum NetAdaptationService {
    public static let host = "47.75.195.35"
    public static let port: UInt16 = 5002

    public static func query(_ info: NetPeripheralInfo) async throws -> NetAdaptation {
        try await query(info, host: host, port: port)
    }
    static func query(_ info: NetPeripheralInfo, host: String, port: UInt16) async throws -> NetAdaptation {
        guard !info.isEmpty else { throw KMError.invalid("外设标识全零，无法查询对应适配方案。") }
        let socket = try HostServiceSocket(type: SOCK_STREAM, timeout: 5)
        try await socket.connect(host: host, port: port)
        try await socket.send(packet(info: info, opcode: 0xa1))
        return try NetAdaptation(data: await socket.receive(count: 40), peripheral: info)
    }

    /// Only called by an explicit user submission; local mode writes never upload feedback.
    public static func submit(info: NetPeripheralInfo, modes: NetParsingModes, worked: Bool,
                              previousCount: UInt32 = 0) async throws -> UInt32 {
        guard !info.isEmpty, previousCount < UInt32.max else { throw KMError.invalid("外设标识或反馈计数无效。") }
        var data = packet(info: info, opcode: worked ? 0xaa : 0xab)
        data.setHostWord(UInt32(modes.mouse), at: 20); data.setHostWord(UInt32(modes.keyboard), at: 24)
        data.setHostWord(previousCount + 1, at: 32)
        let socket = try HostServiceSocket(type: SOCK_STREAM, timeout: 5)
        try await socket.connect(host: host, port: port)
        try await socket.send(data)
        // The original helper exposes this raw return code; its success semantics are undocumented.
        return try await socket.receive(count: 40).hostWord(at: 28)
    }

    static func packet(info: NetPeripheralInfo, opcode: UInt8) -> Data {
        var data = Data(repeating: 0, count: 40); data[0] = opcode
        data.replaceSubrange(1..<9, with: String(format: "%04X%04X", info.vendorID, info.productID).utf8)
        data.replaceSubrange(10..<18, with: String(format: "%04X%04X", info.deviceID, info.hidID).utf8)
        return data
    }
}

private extension Data {
    func hostWord(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[startIndex + offset + $1]) << ($1 * 8) }
    }
    mutating func setHostWord(_ value: UInt32, at offset: Int) {
        replaceSubrange(offset..<offset + 4, with: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
}

/// One bounded transaction owns one socket. TCP handles fragmented replies and short writes.
private final class HostServiceSocket {
    let fd: Int32
    let deadline: TimeInterval
    init(type: Int32, local: String = "", timeout: TimeInterval) throws {
        guard timeout.isFinite, (0.05...10).contains(timeout) else { throw KMError.invalid("通信超时范围为 0.05–10 秒。") }
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { throw socketError("创建诊断套接字") }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw socketError("设置非阻塞通信") }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw socketError("设置诊断套接字") }
        if !local.isEmpty {
            var address = try socketAddress(local, port: 0)
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard result == 0 else { throw socketError("绑定诊断接口") }
        }
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    func connect(host: String, port: UInt16) async throws {
        var address = try socketAddress(host, port: port)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if result == 0 { return }
        guard errno == EINPROGRESS else { throw socketError("连接诊断服务") }
        while true {
            try await pause()
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, 0)
            if ready < 0 { if errno == EINTR { continue }; throw socketError("检查诊断连接") }
            if ready == 0 { continue }
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw socketError("读取连接结果") }
            guard error == 0 else { throw KMError.io("连接诊断服务失败：\(String(cString: strerror(error)))") }
            return
        }
    }
    func send(_ data: Data) async throws {
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if count > 0 { offset += count; continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { try await pause(); continue }
            throw socketError("发送诊断请求（未自动重发）")
        }
    }
    func receive(count: Int, exact: Bool = true) async throws -> Data {
        var result = Data()
        while result.count < count {
            try Task.checkCancellation()
            var bytes = [UInt8](repeating: 0, count: count - result.count)
            let received = recv(fd, &bytes, bytes.count, 0)
            if received > 0 { result.append(contentsOf: bytes.prefix(received)); if !exact { return result }; continue }
            if received == 0 { throw KMError.device("诊断服务提前关闭连接，应答只有 \(result.count) 字节。") }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { try await pause(); continue }
            throw socketError("接收诊断应答")
        }
        return result
    }
    private func pause() async throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw KMError.timeout("诊断服务未完整应答；请求没有自动重发。") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
