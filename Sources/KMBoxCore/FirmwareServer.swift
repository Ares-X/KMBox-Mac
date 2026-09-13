import Foundation
import Darwin

public struct FirmwareServerStatus: Sendable {
    public let active: Bool
    public let port: UInt16
    public let bytesSent: Int
    public let completedDownloads: Int
    public let message: String
}

/// A single immutable NB firmware file, served only to an explicitly selected local IPv4.
/// The box initiates the download from its own update screen. No flash command is sent.
public final class FirmwareServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "kmbox.nb.firmware")
    private let lock = NSLock()
    private let lifecycle = NSLock()
    private var active = false
    private var listenPort: UInt16 = 0
    private var bytesSent = 0
    private var completedDownloads = 0
    private var message = "固件服务未启动"
    public init() {}

    public func status() -> FirmwareServerStatus {
        lock.lock(); defer { lock.unlock() }
        return FirmwareServerStatus(active: active, port: listenPort, bytesSent: bytesSent,
                                    completedDownloads: completedDownloads, message: message)
    }
    private func update(_ text: String, bytes: Int? = nil, completed: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        message = text
        if let bytes { bytesSent = bytes }
        if completed { completedDownloads += 1 }
    }

    @discardableResult
    public func start(firmware: NBFirmware, localAddress: String, deviceAddress: String? = nil, port: UInt16 = 80) throws -> UInt16 {
        lifecycle.lock(); defer { lifecycle.unlock() }
        lock.lock()
        defer { lock.unlock() }
        guard !active else { throw KMError.invalid("请先停止当前固件服务。") }
        let peerText = deviceAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard localAddress != "0.0.0.0", peerText != "0.0.0.0" else { throw KMError.invalid("请选择具体网卡 IPv4；来源限制不能填写 0.0.0.0。") }
        var local = try socketAddress(localAddress, port: port)
        let expectedLocal = local.sin_addr.s_addr
        guard let interface = NetworkInterface.available().first(where: { $0.address == localAddress }) else {
            throw KMError.invalid("Mac 上没有启用此 IPv4 的网卡，请刷新后重新选择。")
        }
        var interfaceIndex = if_nametoindex(interface.name)
        guard interfaceIndex != 0 else { throw socketError("识别固件网卡") }
        let allowedPeer = peerText.isEmpty ? nil : try socketAddress(peerText, port: 0).sin_addr.s_addr
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("创建固件服务") }
        do {
            guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &interfaceIndex, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
                throw socketError("限定固件服务网卡")
            }
            var yes: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            // XNU in_pcbbind permits non-root low-port binding only with INADDR_ANY.
            // IP_BOUND_IF restricts the interface; accept additionally checks the exact
            // destination address before reading any HTTP bytes or serving the image.
            if port > 0 && port < 1024 { local.sin_addr.s_addr = INADDR_ANY }
            guard withUnsafePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }) == 0 else { throw socketError("绑定 \(localAddress):\(port)；请检查地址、端口占用和系统权限") }
            guard listen(fd, 4) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw socketError("监听固件服务") }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            guard withUnsafeMutablePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            } }) == 0 else { throw socketError("读取服务端口") }
            listenPort = UInt16(bigEndian: local.sin_port)
            active = true; bytesSent = 0; completedDownloads = 0
            message = "等待 NB 请求 /kmboxNB.cpio；请在盒子升级页填入 Mac 地址 \(localAddress)"
            queue.async { self.serve(fd: fd, firmware: firmware, allowedPeer: allowedPeer, expectedLocal: expectedLocal) }
            return listenPort
        } catch { Darwin.close(fd); throw error }
    }

    public func stop() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        lock.lock(); active = false; lock.unlock()
        // The worker owns and closes all descriptors; never close/reuse an fd under a pending send.
        queue.sync {}
        update("固件服务已停止；设备刷写结果请在盒子上核对")
    }

    private func serve(fd: Int32, firmware: NBFirmware, allowedPeer: in_addr_t?, expectedLocal: in_addr_t) {
        defer { Darwin.close(fd) }
        while status().active {
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                update(socketError("监听固件请求").localizedDescription)
                break
            }
            if ready == 0 { continue }
            var peer = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(fd, $0, &size)
            } }
            if client < 0 { continue }
            defer { Darwin.close(client) }
            if let allowedPeer, peer.sin_addr.s_addr != allowedPeer { update("已拒绝其他来源的固件请求"); continue }
            var destination = sockaddr_in(), destinationSize = socklen_t(MemoryLayout<sockaddr_in>.size)
            guard withUnsafeMutablePointer(to: &destination, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(client, $0, &destinationSize)
            } }) == 0, destination.sin_addr.s_addr == expectedLocal else {
                update("已拒绝发往其他 Mac 地址的固件请求"); continue
            }
            var yes: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            guard fcntl(client, F_SETFL, O_NONBLOCK) == 0 else { update(socketError("设置下载连接").localizedDescription); continue }
            do { try handle(client, firmware: firmware) }
            catch { update("传输未完成：" + error.localizedDescription) }
        }
        lock.lock(); active = false; lock.unlock()
    }

    private func handle(_ fd: Int32, firmware: NBFirmware) throws {
        var request = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard status().active else { throw KMError.io("服务已停止") }
            guard DispatchTime.now().uptimeNanoseconds < deadline, request.count <= 8192 else { throw KMError.invalid("HTTP 请求超时或过长") }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 50) <= 0 { continue }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 { throw KMError.io("请求端断开") }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw socketError("读取固件请求")
            }
            request.append(contentsOf: buffer.prefix(count))
        }
        guard request.count <= 8192 else { throw KMError.invalid("HTTP 请求过长") }
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(first[2])) else {
            try respond(fd, status: "400 Bad Request", body: Data()); return
        }
        guard ["GET", "HEAD"].contains(String(first[0])) else { try respond(fd, status: "405 Method Not Allowed", body: Data()); return }
        guard first[1] == "/kmboxNB.cpio" else { try respond(fd, status: "404 Not Found", body: Data()); return }
        // Send the whole immutable file; RFC 9110 permits ignoring Range and returning 200.
        // This avoids claiming resume support absent a verified firmware-client contract.
        let head = first[0] == "HEAD"
        update(head ? "收到文件信息查询" : "正在发送固件；请保持应用与连接开启", bytes: 0)
        try respond(fd, status: "200 OK", body: firmware.data, head: head, firmware: true)
        if !head { update("固件字节已发送完毕；尚未确认盒子刷写或重启成功", completed: true) }
    }

    private func respond(_ fd: Int32, status statusLine: String, body: Data, head: Bool = false, firmware: Bool = false) throws {
        let header = "HTTP/1.0 \(statusLine)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        try send(fd, data: Data(header.utf8), track: false)
        if !head { try send(fd, data: body, track: firmware) }
    }

    private func send(_ fd: Int32, data: Data, track: Bool) throws {
        var offset = 0
        var deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        while offset < data.count {
            guard status().active else { throw KMError.io("服务已停止") }
            let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), min(65536, data.count - offset), 0) }
            if count > 0 {
                offset += count; deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
                if track { update("已发送 \(offset) / \(data.count) 字节；等待设备完成刷写", bytes: offset) }
                continue
            }
            if count < 0, errno != EINTR, errno != EAGAIN { throw socketError("发送固件") }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw KMError.timeout("下载端 10 秒未接收数据") }
            var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&event, 1, 50)
        }
    }
}
