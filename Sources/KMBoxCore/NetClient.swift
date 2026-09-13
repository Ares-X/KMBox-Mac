import Foundation
import Darwin

public struct NetReceipt: Sendable {
    public let sequence: UInt32
    public let command: UInt32
    public let milliseconds: Double
    public let ignoredResponses: Int
    public let bytesSent: Int
    public let responseParameter: UInt32
    public let responsePayload: Data
}

public struct NetStatus: Sendable {
    public let connected: Bool
    public let uncertain: Bool
    public let mouse: MouseState
    public let keyboard: KeyboardState
    public let monitorPort: UInt16?
    public let monitorNeedsStop: Bool
}

/// One owner for sequence numbers, button state and UDP transactions.
/// A transaction never suspends halfway through, so actor reentrancy cannot interleave packets.
public actor NetClient {
    private var descriptor: Int32 = -1
    private var configuration: NetConfiguration?
    private var sequence: UInt32 = 0
    private var mouse = MouseState()
    private var keyboard = KeyboardState()
    private var uncertain = false
    private var monitor: NetMonitorReceiver?
    private var monitorNeedsStop = false

    private var transactionStatistics = NetTransactionStatistics()

    public init() {}
    public func statistics() -> NetTransactionStatistics { transactionStatistics }
    public func clearStatistics() { transactionStatistics = NetTransactionStatistics() }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    public func status() -> NetStatus {
        NetStatus(connected: descriptor >= 0 && configuration != nil, uncertain: uncertain, mouse: mouse, keyboard: keyboard,
                  monitorPort: monitor?.port, monitorNeedsStop: monitorNeedsStop)
    }

    public func connect(_ config: NetConfiguration) throws -> NetReceipt {
        guard descriptor < 0 else { throw KMError.invalid("请先断开当前设备。") }
        clearStatistics()
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw socketError("创建 UDP 套接字") }
        descriptor = fd
        do {
            if let local = config.localAddress {
                var address = try socketAddress(local, port: 0)
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                guard result == 0 else { throw socketError("绑定本机接口 \(local)") }
            }
            var peer = try socketAddress(config.host, port: config.port)
            let result = withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 else { throw socketError("连接 UDP 目标") }
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw socketError("设置 UDP 非阻塞模式") }
            configuration = config; sequence = 0; mouse = MouseState(); keyboard = KeyboardState(); uncertain = false
            return try exchange(.connect, payload: Data(), isHandshake: true)
        } catch {
            closeSocket()
            throw error
        }
    }

    /// Explicit releases are attempted independently; never abandon the keyboard release because the mouse timed out.
    public func releaseAll() throws -> [NetReceipt] {
        guard descriptor >= 0 else { throw KMError.disconnected }
        var receipts: [NetReceipt] = []
        var failures: [String] = []
        do {
            receipts.append(try exchange(.wheel, payload: MouseState().payload(), recovery: true))
            mouse = MouseState()
        } catch { failures.append("鼠标：\(error.localizedDescription)") }
        do {
            receipts.append(try exchange(.keyboard, payload: KeyboardState().payload, recovery: true))
            keyboard = KeyboardState()
        } catch { failures.append("键盘：\(error.localizedDescription)") }
        uncertain = !failures.isEmpty
        if !failures.isEmpty { throw KMError.uncertain(failures.joined(separator: "；")) }
        return receipts
    }

    public func disconnect() throws {
        guard descriptor >= 0 else { return }
        defer { closeSocket() }
        try prepareToClose()
    }

    private func prepareToClose() throws {
        var failures: [String] = []
        if monitorNeedsStop {
            do { _ = try stopMonitor() } catch { failures.append(error.localizedDescription) }
        }
        if uncertain || mouse.buttons != 0 || keyboard.modifiers != 0 || !keyboard.keys.isEmpty {
            do { _ = try releaseAll() } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw KMError.device(failures.joined(separator: "；")) }
    }

    public func peripheralInfo() throws -> (NetPeripheralInfo, NetReceipt) {
        let receipt = try exchange(.peripheral, payload: Data(repeating: 0, count: 10), parameter: 0,
                                   effect: .query, minimumResponseBytes: 26)
        return (try NetPeripheralInfo(data: receipt.responsePayload), receipt)
    }

    /// Preserve the peripheral identity fields and verify the modes with a separate device read.
    public func setParsing(_ modes: NetParsingModes, expectedPeripheral: NetPeripheralInfo? = nil) throws -> (NetPeripheralInfo, [NetReceipt]) {
        let (before, read) = try peripheralInfo()
        guard !before.isEmpty else { throw KMError.device("外设标识全为零，无法为未识别的外设保存解析参数。") }
        if let expectedPeripheral, expectedPeripheral.raw.prefix(8) != before.raw.prefix(8) {
            throw KMError.conflict("外设已经更换，请为当前外设重新查询适配方案。未写入参数。")
        }
        let write = try exchange(.peripheral, payload: before.payload(with: modes), parameter: 1, effect: .configuration)
        do {
            let (after, verify) = try peripheralInfo()
            guard after.raw.prefix(8) == before.raw.prefix(8), after.mouseMode == modes.mouse, after.keyboardMode == modes.keyboard else {
                throw KMError.device("回读值与请求不一致（外设可能已更换或固件未应用设置）。")
            }
            return (after, [read, write, verify])
        } catch { throw KMError.device("解析参数已收到写入应答，但未通过回读确认：\(error.localizedDescription)") }
    }

    public func setNetwork(_ settings: NetNetworkSettings) throws -> NetReceipt {
        try exchange(.setNetwork, payload: settings.payload, parameter: settings.parameter, effect: .configuration)
    }
    public func setVIDPID(vendor: UInt16, product: UInt16) throws -> NetReceipt {
        try exchange(.setVIDPID, payload: Data(), parameter: UInt32(vendor) | UInt32(product) << 16, effect: .configuration)
    }
    public func setCurve(_ settings: NetCurveSettings) throws -> NetReceipt {
        try exchange(.curve, payload: Data(), parameter: settings.parameter, effect: .configuration)
    }
    /// Firmware applies this setting on reboot; reboot is a separate explicit operation.
    public func setBypass(_ enabled: Bool) throws -> NetReceipt {
        try exchange(.bypass, payload: Data(), parameter: enabled ? 1 : 0, effect: .configuration)
    }
    public func reboot() throws -> NetReceipt {
        guard descriptor >= 0 else { throw KMError.disconnected }
        try prepareToClose()
        defer { closeSocket() }
        return try exchange(.reboot, payload: Data(), effect: .configuration)
    }

    public func startMonitor(port: UInt16 = 6688) throws -> NetReceipt {
        guard let config = configuration, descriptor >= 0 else { throw KMError.disconnected }
        guard !monitorNeedsStop else { throw KMError.invalid("请先停止当前监控，再启动新的接收端口。") }
        var local = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { throw socketError("读取本机网络地址") }
        monitor = try NetMonitorReceiver(local: local, host: config.host, port: port)
        monitorNeedsStop = true
        return try exchange(.monitor, payload: Data(), parameter: 0xaa550000 | UInt32(port), effect: .configuration)
    }
    public func readMonitor() throws -> NetMonitorBatch {
        guard let monitor else { throw KMError.invalid("尚未启动本机监控接收。") }
        return try monitor.read()
    }
    public func stopMonitor() throws -> NetReceipt {
        guard monitorNeedsStop else { throw KMError.invalid("本连接没有启动监控。") }
        defer { monitor = nil }
        let receipt = try exchange(.monitor, payload: Data(), parameter: 0, effect: .configuration)
        monitorNeedsStop = false
        return receipt
    }

    public func move(x: Int32, y: Int32) throws -> NetReceipt {
        try validateMouseCoordinates(x, y)
        return try exchange(.move, payload: mouse.payload(x: x, y: y))
    }

    public func moveAutomatically(_ movement: NetTimedMovement) throws -> NetReceipt {
        try timedMove(movement, command: .automaticMove, controls: nil)
    }
    public func moveBezier(_ movement: NetTimedMovement, controls: NetBezierControls) throws -> NetReceipt {
        try timedMove(movement, command: .bezierMove, controls: controls)
    }
    private func timedMove(_ movement: NetTimedMovement, command: NetCommand, controls: NetBezierControls?) throws -> NetReceipt {
        try exchange(command, payload: mouse.payload(x: movement.x, y: movement.y, controls: controls),
                     parameter: movement.milliseconds, additionalWait: Double(movement.milliseconds) / 1000)
    }

    public func scroll(_ amount: Int32) throws -> NetReceipt {
        guard (-127...127).contains(amount) else { throw KMError.invalid("滚轮步数范围为 -127…127。") }
        return try exchange(.wheel, payload: mouse.payload(wheel: amount))
    }

    public func setMouseButton(_ bit: Int32, down: Bool) throws -> NetReceipt {
        let command: NetCommand
        switch bit {
        case 1: command = .left
        case 2: command = .right
        case 4: command = .middle
        case 8, 16: command = .wheel
        default: throw KMError.invalid("无效的鼠标按键。")
        }
        var next = mouse
        if down { next.buttons |= bit } else { next.buttons &= ~bit }
        let result = try exchange(command, payload: next.payload())
        mouse = next
        return result
    }

    public func click(_ bit: Int32 = 1) throws -> [NetReceipt] {
        guard mouse.buttons & bit == 0 else { throw KMError.invalid("该按键已保持按下，请先释放。") }
        let down = try setMouseButton(bit, down: true)
        Thread.sleep(forTimeInterval: 0.04)
        let up = try setMouseButton(bit, down: false)
        return [down, up]
    }

    public func setKey(_ key: UInt8, down: Bool) throws -> NetReceipt {
        var next = keyboard
        try next.set(key, down: down)
        let result = try exchange(.keyboard, payload: next.payload)
        keyboard = next
        return result
    }

    public func tapKey(_ key: UInt8, modifiers: [UInt8] = []) throws -> [NetReceipt] {
        let previous = keyboard
        var next = previous
        let modifierAlreadyDown = (0xe0...0xe7).contains(key) && previous.modifiers & (1 << (key - 0xe0)) != 0
        guard !previous.keys.contains(key) && !modifierAlreadyDown else { throw KMError.invalid("该键已保持按下，请先释放。") }
        for modifier in modifiers {
            guard (0xe0...0xe7).contains(modifier) else { throw KMError.invalid("修饰键编码无效。") }
            try next.set(modifier, down: true)
        }
        try next.set(key, down: true)
        let down = try exchange(.keyboard, payload: next.payload)
        keyboard = next
        Thread.sleep(forTimeInterval: 0.04)
        let up = try exchange(.keyboard, payload: previous.payload)
        keyboard = previous
        return [down, up]
    }

    private enum Effect { case input, query, configuration }
    private func exchange(_ command: NetCommand, payload: Data, isHandshake: Bool = false,
                          recovery: Bool = false, parameter: UInt32? = nil, effect: Effect = .input,
                          minimumResponseBytes: Int = 16, additionalWait: TimeInterval = 0) throws -> NetReceipt {
        guard let config = configuration, descriptor >= 0 else { throw KMError.disconnected }
        guard !uncertain || recovery || effect != .input else { throw KMError.uncertain("上一条指令未收到有效应答") }
        if !isHandshake { sequence &+= 1 }
        let header = PacketHeader(uuid: config.uuid, random: parameter ?? UInt32.random(in: 0...UInt32.max),
                                  sequence: sequence, command: command.rawValue)
        let data = header.data + payload
        let started = DispatchTime.now().uptimeNanoseconds
        let sent = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        guard sent == data.count else { throw socketError("发送 UDP 报文") }
        transactionStatistics.didSend(bytes: data.count)
        let deadline = started + UInt64((config.timeout + additionalWait) * 1_000_000_000)
        var ignored = 0
        var detail = "未收到应答"
        do {
            while DispatchTime.now().uptimeNanoseconds < deadline {
                let remaining = deadline - min(deadline, DispatchTime.now().uptimeNanoseconds)
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&event, 1, Int32(max(1, min(100, remaining / 1_000_000))))
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw socketError("等待 UDP 应答")
                }
                if ready == 0 { continue }
                var buffer = [UInt8](repeating: 0, count: 2048)
                let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
                if count < 0 {
                    if errno == EAGAIN || errno == EINTR { continue }
                    throw socketError("接收 UDP 应答")
                }
                guard count >= 16 else { ignored += 1; detail = "收到不足 16 字节的应答"; continue }
                let reply = try PacketHeader(data: Data(buffer.prefix(count)))
                guard reply.command == command.rawValue, reply.sequence == sequence else {
                    ignored += 1; detail = "收到不匹配的命令或序号"; continue
                }
                guard count >= minimumResponseBytes else {
                    ignored += 1; detail = "匹配应答仅 \(count) 字节，需要至少 \(minimumResponseBytes) 字节；固件可能不支持此功能"; continue
                }
                let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                transactionStatistics.didAcknowledge(milliseconds: milliseconds, ignored: ignored)
                return NetReceipt(sequence: sequence, command: command.rawValue,
                                  milliseconds: milliseconds,
                                  ignoredResponses: ignored, bytesSent: data.count,
                                  responseParameter: reply.random, responsePayload: Data(buffer[16..<count]))
            }
            throw KMError.timeout(detail)
        } catch {
            transactionStatistics.didFail(error, ignored: ignored)
            if !isHandshake && effect == .input { uncertain = true; throw KMError.uncertain(error.localizedDescription) }
            if effect == .configuration { throw KMError.device("\(error.localizedDescription)；配置指令已发送，是否执行未知，未自动重发。") }
            throw error
        }
    }

    private func closeSocket() {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1; configuration = nil
        mouse = MouseState(); keyboard = KeyboardState(); uncertain = false
        monitor = nil; monitorNeedsStop = false
    }
}

func socketError(_ operation: String) -> KMError {
    KMError.io("\(operation)失败：\(String(cString: strerror(errno)))")
}

func socketAddress(_ host: String, port: UInt16) throws -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw KMError.invalid("无效的 IPv4 地址：\(host)") }
    return address
}
