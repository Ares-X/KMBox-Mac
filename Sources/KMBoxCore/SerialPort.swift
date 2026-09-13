import Foundation
import Darwin

final class SerialPort {
    static let baudRates: [Int: speed_t] = [9600: speed_t(B9600), 19200: speed_t(B19200),
        38400: speed_t(B38400), 57600: speed_t(B57600), 115200: speed_t(B115200), 230400: speed_t(B230400)]
    private(set) var descriptor: Int32
    private var original = termios()
    private var restoreSettings = false
    private var buffer = Data()

    init(path: String, baud: Int) throws {
        guard let rate = Self.baudRates[baud] else { throw KMError.invalid("不支持的波特率：\(baud)") }
        descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw socketError("打开串口 \(path)") }
        do {
            guard ioctl(descriptor, TIOCEXCL) == 0 else { throw socketError("独占串口") }
            guard tcgetattr(descriptor, &original) == 0 else { throw socketError("读取串口设置") }
            restoreSettings = true
            var settings = original
            cfmakeraw(&settings)
            settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
            settings.c_cflag &= ~tcflag_t(HUPCL | CRTSCTS)
            cfsetispeed(&settings, rate); cfsetospeed(&settings, rate)
            guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else { throw socketError("设置串口参数") }
        } catch { close(); throw error }
    }

    deinit { close() }

    func close() {
        guard descriptor >= 0 else { return }
        if restoreSettings {
            var saved = original
            // Closing this tool must not intentionally reset the board through HUPCL.
            saved.c_cflag &= ~tcflag_t(HUPCL)
            tcsetattr(descriptor, TCSANOW, &saved)
        }
        _ = ioctl(descriptor, TIOCNXCL)
        Darwin.close(descriptor)
        descriptor = -1
    }

    func write(_ data: Data, timeout: TimeInterval = 3) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var offset = 0
        while offset < data.count {
            guard descriptor >= 0 else { throw KMError.disconnected }
            let written = data.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written > 0 { offset += written; continue }
            if written < 0, errno != EAGAIN, errno != EINTR { throw socketError("写串口") }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw KMError.timeout("写入串口") }
            var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            _ = poll(&event, 1, 20)
        }
    }

    func available() throws -> Data {
        guard descriptor >= 0 else { throw KMError.disconnected }
        var output = buffer
        buffer.removeAll(keepingCapacity: true)
        var bytes = [UInt8](repeating: 0, count: 4096)
        // Bound each poll so output-heavy scripts cannot starve the Stop operation.
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 { output.append(contentsOf: bytes.prefix(count)); continue }
            if count < 0, errno != EAGAIN, errno != EINTR { throw socketError("读串口") }
            if count == 0 {
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&event, 1, 0)
                if event.revents & Int16(POLLHUP | POLLERR) != 0 { throw KMError.io("串口设备已断开。") }
            }
            break
        }
        return output
    }

    func readUntil(_ marker: Data, timeout: TimeInterval) throws -> Data {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var accumulated = Data()
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try Task.checkCancellation()
            accumulated.append(try available())
            if let range = accumulated.range(of: marker) {
                let end = range.upperBound
                buffer = Data(accumulated[end...])
                return Data(accumulated[..<range.lowerBound])
            }
            guard accumulated.count <= 4 * 1024 * 1024 else { throw KMError.invalid("设备响应超过 4 MiB。") }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            _ = poll(&event, 1, 10)
        }
        throw KMError.timeout("等待 \(String(reflecting: String(decoding: marker, as: UTF8.self)))；已收到 \(String(reflecting: String(decoding: accumulated.suffix(180), as: UTF8.self)))")
    }
}

public enum SerialDevices {
    public static func available() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth") && !$0.contains("debug-console") }
            .map { "/dev/" + $0 }.sorted()
    }
}
