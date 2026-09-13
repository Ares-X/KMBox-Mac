import XCTest
import Darwin
@testable import KMBoxCore

final class UDPFixture: @unchecked Sendable {
    enum Mode { case normal, delayedTimedMove, staleThenCorrect, shortThenCorrect, dropMove, dropAll, dropWheel, shortInfo, zeroInfo, dropSettings, mismatchParsing }
    private let queue = DispatchQueue(label: "test.kmbox.udp")
    private let lock = NSLock()
    private var active = true
    private var _mode: Mode = .normal
    private var received: [Data] = []
    private let fd: Int32
    let port: UInt16

    var mode: Mode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }
    var packets: [Data] { lock.lock(); defer { lock.unlock() }; return received }

    init() throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        fd = descriptor
        var address = try socketAddress("127.0.0.1", port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { Darwin.close(fd); throw socketError("绑定测试 UDP") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        queue.async { self.loop() }
    }

    func stop() {
        lock.lock(); let wasActive = active; active = false; lock.unlock()
        if wasActive { queue.sync {}; Darwin.close(fd) }
    }

    private func loop() {
        var info = Data([0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a, 0xf0, 0xde, 2, 3])
        while true {
            lock.lock(); let keepRunning = active; lock.unlock()
            if !keepRunning { return }
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 20) > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: 2048)
            var peer = sockaddr_storage(), length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &bytes, bytes.count, 0, $0, &length) }
            }
            guard count >= 16 else { continue }
            let data = Data(bytes.prefix(count))
            lock.lock(); received.append(data); let currentMode = _mode; lock.unlock()
            guard let header = try? PacketHeader(data: data) else { continue }
            if (currentMode == .dropWheel && header.command == NetCommand.wheel.rawValue) || currentMode == .dropAll || (currentMode == .dropMove && [NetCommand.move, .automaticMove, .bezierMove].map(\.rawValue).contains(header.command)) { continue }
            func send(_ payload: Data) {
                payload.withUnsafeBytes { raw in
                    _ = withUnsafePointer(to: &peer) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, raw.baseAddress, raw.count, 0, $0, length) }
                    }
                }
            }
            if currentMode == .delayedTimedMove && [NetCommand.automaticMove, .bezierMove].map(\.rawValue).contains(header.command) { Thread.sleep(forTimeInterval: 0.15) }
            if currentMode == .staleThenCorrect {
                send(PacketHeader(uuid: header.uuid, random: 0, sequence: header.sequence &- 1, command: header.command).data)
            }
            if currentMode == .shortThenCorrect { send(Data([1, 2, 3])) }
            if currentMode == .dropSettings && [NetCommand.setNetwork, .curve, .setVIDPID, .bypass, .monitor, .reboot].map({ $0.rawValue }).contains(header.command) { continue }
            if header.command == NetCommand.peripheral.rawValue && currentMode != .shortInfo {
                if header.random == 1 && data.count == 26 && currentMode != .mismatchParsing { info = Data(data.suffix(10)) }
                send(header.data + (currentMode == .zeroInfo ? Data(repeating: 0, count: 10) : info))
            } else { send(header.data) }
            if header.command == NetCommand.monitor.rawValue && header.random != 0 {
                var target = sockaddr_in()
                withUnsafePointer(to: &peer) { pointer in
                    target = pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                }
                target.sin_port = UInt16(truncatingIfNeeded: header.random).bigEndian
                func report(_ data: Data, from socket: Int32) {
                    data.withUnsafeBytes { raw in
                        _ = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socket, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
                    }
                }
                let frame = Data([1, 5, 0xfd, 0xff, 7, 0, 0xff, 0xff, 2, 2, 4, 26, 0, 0, 0, 0, 0, 0, 0, 0])
                report(frame, from: fd); report(Data([0, 1, 2]), from: fd)

            }
        }
    }
}

final class NetClientTests: XCTestCase {
    func testRealLoopbackSocketRejectsStaleAndShortResponses() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = NetClient()
        let config = try NetConfiguration(host: "127.0.0.1", port: String(server.port), uuid: "12345678", timeout: 0.2)
        server.mode = .staleThenCorrect
        let connected = try await client.connect(config)
        XCTAssertEqual(connected.ignoredResponses, 1)
        server.mode = .shortThenCorrect
        let moved = try await client.move(x: -10, y: 20)
        XCTAssertEqual(moved.sequence, 1); XCTAssertEqual(moved.ignoredResponses, 1)
        XCTAssertEqual(moved.bytesSent, 72)
        try await client.disconnect()
    }

    func testTimeoutDoesNotResendAndBlocksFurtherMotionUntilExplicitRecovery() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = NetClient()
        _ = try await client.connect(NetConfiguration(host: "127.0.0.1", port: String(server.port), uuid: "1", timeout: 0.1))
        server.mode = .dropMove
        do { _ = try await client.move(x: 5, y: 0); XCTFail("Expected timeout") }
        catch { guard case KMError.uncertain = error else { return XCTFail("Wrong error: \(error)") } }
        do { _ = try await client.move(x: 5, y: 0); XCTFail("Must block new motion") } catch {}
        XCTAssertEqual(server.packets.count, 2, "Only connect and a single move may be transmitted")
        let status = await client.status(); XCTAssertTrue(status.uncertain)
        server.mode = .normal
        let released = try await client.releaseAll(); XCTAssertEqual(released.count, 2)
        let recovered = await client.status(); XCTAssertFalse(recovered.uncertain)
        _ = try await client.move(x: 1, y: 0)
        try await client.disconnect()
    }

    func testDisconnectReleasesHeldKeysBeforeClosing() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = NetClient()
        _ = try await client.connect(NetConfiguration(host: "127.0.0.1", port: String(server.port), uuid: "1", timeout: 0.2))
        _ = try await client.setMouseButton(1, down: true)
        _ = try await client.setKey(4, down: true)
        try await client.disconnect()
        let packets = server.packets
        XCTAssertEqual(packets.count, 5)
        XCTAssertEqual(packets[3].suffix(56), Data(repeating: 0, count: 56))
        XCTAssertEqual(packets[4].suffix(12), Data(repeating: 0, count: 12))
    }

    func testMouseReleaseFailureStillReleasesKeyboardAndRequiresRecovery() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = NetClient()
        _ = try await client.connect(NetConfiguration(host: "127.0.0.1", port: String(server.port), uuid: "1", timeout: 0.1))
        _ = try await client.setKey(4, down: true)
        server.mode = .dropWheel
        do { _ = try await client.releaseAll(); XCTFail("Missing mouse acknowledgement must not be success") } catch {}
        let state = await client.status()
        XCTAssertTrue(state.uncertain)
        XCTAssertTrue(state.keyboard.keys.isEmpty)
        XCTAssertEqual(try PacketHeader(data: server.packets.last!).command, NetCommand.keyboard.rawValue)
        XCTAssertEqual(server.packets.last!.suffix(12), Data(repeating: 0, count: 12))
        server.mode = .normal
        _ = try await client.releaseAll()
        try await client.disconnect()
    }

    func testTapRestoresPreviouslyHeldKeyboardState() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = NetClient()
        _ = try await client.connect(NetConfiguration(host: "127.0.0.1", port: String(server.port), uuid: "1", timeout: 0.1))
        _ = try await client.setKey(0xe1, down: true)
        _ = try await client.setKey(5, down: true)
        _ = try await client.tapKey(4, modifiers: [0xe0])
        let state = await client.status()
        XCTAssertEqual(state.keyboard.modifiers, 2)
        XCTAssertEqual(state.keyboard.keys, [5])
        let packets = server.packets
        XCTAssertEqual(Array(packets[3].suffix(12).prefix(4)), [3, 0, 5, 4])
        XCTAssertEqual(Array(packets[4].suffix(12).prefix(4)), [2, 0, 5, 0])
        try await client.disconnect()
    }

    func testHandshakeCannotSucceedWithoutReply() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        server.mode = .dropAll
        let client = NetClient()
        do {
            _ = try await client.connect(NetConfiguration(host: "127.0.0.1", port: String(server.port), uuid: "1", timeout: 0.1))
            XCTFail("Expected timeout")
        } catch {}
        let status = await client.status(); XCTAssertFalse(status.connected)
    }
}
