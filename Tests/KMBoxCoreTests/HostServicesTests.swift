import XCTest
import Darwin
import ImageIO
import CoreGraphics
@testable import KMBoxCore
@testable import KMBoxApp

final class HostServicesTests: XCTestCase {
    private func info() throws -> NetPeripheralInfo { try NetPeripheralInfo(data: Data([0x34,0x12,0x78,0x56,0xbc,0x9a,0xf0,0xde,2,3])) }
    private func reply(status: UInt8 = 1, mouse: UInt8 = 4) -> Data {
        var data = Data(repeating: 0, count: 40)
        data[20] = mouse; data[24] = 5; data[28] = status; data[32] = 7; data[36] = 9
        return data
    }

    func testAdaptationRequestUsesExactIdentityOrderAndZeroPadding() throws {
        let data = NetAdaptationService.packet(info: try info(), opcode: 0xa1)
        XCTAssertEqual(data.count, 40)
        XCTAssertEqual(Array(data.prefix(20)), [0xa1] + Array("12345678".utf8) + [0] + Array("DEF09ABC".utf8) + [0,0])
        XCTAssertEqual(data.suffix(20), Data(repeating: 0, count: 20))
    }

    func testAdaptationHandlesFragmentedTCPReply() async throws {
        let server = try HostTCPFixture(reply: reply(), fragment: 3); defer { server.stop() }
        let result = try await NetAdaptationService.query(info(), host: "127.0.0.1", port: server.port)
        XCTAssertEqual(result.modes, try NetParsingModes(mouse: 4, keyboard: 5))
        XCTAssertEqual(result.successes, 7); XCTAssertEqual(result.failures, 9)
        XCTAssertEqual(server.request, NetAdaptationService.packet(info: try info(), opcode: 0xa1))
    }

    func testAdaptationRejectsTruncatedAndUnknownResponses() async throws {
        let peripheral = try info()
        XCTAssertThrowsError(try NetAdaptation(data: reply(status: 3), peripheral: peripheral))
        XCTAssertThrowsError(try NetAdaptation(data: reply(status: 9), peripheral: peripheral))
        XCTAssertThrowsError(try NetAdaptation(data: reply(mouse: 33), peripheral: peripheral))
        let server = try HostTCPFixture(reply: reply().prefix(30), fragment: 30); defer { server.stop() }
        do { _ = try await NetAdaptationService.query(peripheral, host: "127.0.0.1", port: server.port); XCTFail("Short TCP reply cannot be success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("30 字节")) }
    }

    func testChipQueryLayoutAndReplyLength() throws {
        let request = NetChipID.request
        XCTAssertEqual(request.count, 1024)
        XCTAssertEqual(Array(request.prefix(16)), [0,0,0,0,0xba,0xba,0xfe,0xef,0,0,0,0,0xba,0xba,0xfe,0xef])
        XCTAssertEqual(request.dropFirst(16), Data(repeating: 0, count: 1008))
        var data = Data(repeating: 0, count: 28)
        data.replaceSubrange(16..<28, with: [0x78,0x56,0x34,0x12,1,0,0,0,0xef,0xbe,0xad,0xde])
        XCTAssertEqual(try NetChipID(data: data).text, "12345678-00000001-DEADBEEF")
        XCTAssertThrowsError(try NetChipID(data: data.prefix(27)))
        XCTAssertThrowsError(try NetChipID(data: Data(repeating: 0, count: 28)))
    }

    func testChipQueryUsesChosenPeerAndLocalInterface() async throws {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0); XCTAssertGreaterThanOrEqual(socket, 0)
        defer { Darwin.close(socket) }
        var address = try socketAddress("127.0.0.1", port: 0)
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }, 0)
        XCTAssertEqual(fcntl(socket, F_SETFL, O_NONBLOCK), 0)
        let port = UInt16(bigEndian: address.sin_port)
        let query = Task { try await NetHostDiagnostics.chipID(host: "127.0.0.1", localAddress: "127.0.0.1", port: port) }
        var bytes = [UInt8](repeating: 0, count: 2048), peer = sockaddr_in(), received = -1
        let deadline = Date().addingTimeInterval(1)
        repeat {
            received = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socket, &bytes, bytes.count, 0, $0, &length) } }
            if received < 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        } while received < 0 && Date() < deadline
        XCTAssertEqual(received, 1024); XCTAssertEqual(Data(bytes.prefix(max(0, received))), NetChipID.request)
        var response = Data(repeating: 0, count: 28); response[16] = 1
        _ = response.withUnsafeBytes { buffer in withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(socket, buffer.baseAddress, buffer.count, 0, $0, length) } } }
        let result = try await query.value; XCTAssertEqual(result.words, [1,0,0])
    }

    func testPingLoopbackWithoutNetHandshakeAndRejectsInvalidHost() async throws {
        let result = try await NetHostDiagnostics.ping(host: "127.0.0.1", localAddress: "127.0.0.1")
        XCTAssertTrue(result.reached, result.output); XCTAssertNotNil(result.milliseconds)
        do { _ = try await NetHostDiagnostics.ping(host: "--help"); XCTFail("Host must be an address") } catch { }
    }

    func testAutomaticCaptureTriggersOnlyOnNewLeftPress() {
        var edge = MousePressEdge()
        XCTAssertFalse(edge.consume(buttons: 1))
        XCTAssertFalse(edge.consume(buttons: 1)); XCTAssertFalse(edge.consume(buttons: 0))
        XCTAssertTrue(edge.consume(buttons: 1)); XCTAssertFalse(edge.consume(buttons: 3))
        XCTAssertFalse(edge.consume(buttons: 2)); XCTAssertTrue(edge.consume(buttons: 3))
        edge.reset(); XCTAssertFalse(edge.consume(buttons: 1))
    }

    func testEveryOfferedSnapshotFormatCanEncodeAndDecodeImageDimensions() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        let image = try XCTUnwrap(context.makeImage())
        for format in SnapshotFormat.allCases {
            let data = try SnapshotFormat.encode(image, as: format)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), format.rawValue)
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), format.rawValue)
            XCTAssertEqual(decoded.width, 48); XCTAssertEqual(decoded.height, 32)
        }
    }

    func testAdaptationCannotWriteRecommendationForReplacedPeripheral() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = NetClient(); _ = try await client.connect(NetConfiguration(host: "127.0.0.1", port: String(server.port), uuid: "1"))
        let different = try NetPeripheralInfo(data: Data(repeating: 1, count: 10))
        do { _ = try await client.setParsing(NetParsingModes(mouse: 4, keyboard: 5), expectedPeripheral: different); XCTFail("Must reject replaced peripheral") }
        catch { XCTAssertTrue(error.localizedDescription.contains("已经更换")) }
        let (current, _) = try await client.peripheralInfo()
        XCTAssertEqual(current.mouseMode, 2); XCTAssertEqual(current.keyboardMode, 3)
        try await client.disconnect()
    }
}

private final class HostTCPFixture: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let fd: Int32
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data = Data()
    var request: Data { lock.lock(); defer { lock.unlock() }; return data }
    init(reply: Data, fragment: Int) throws {
        fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw socketError("fixture socket") }
        var address = try socketAddress("127.0.0.1", port: 0), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) } }
        guard bound == 0, listen(fd, 1) == 0 else { Darwin.close(fd); throw socketError("fixture bind/listen") }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        group.enter()
        DispatchQueue.global().async { [self] in
            defer { group.leave() }
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { return }; defer { Darwin.close(connection) }
            var timeout = timeval(tv_sec: 1, tv_usec: 0), one: Int32 = 1
            _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var incoming = Data()
            while incoming.count < 40 {
                var bytes = [UInt8](repeating: 0, count: 40 - incoming.count)
                let received = recv(connection, &bytes, bytes.count, 0); if received <= 0 { return }
                incoming.append(contentsOf: bytes.prefix(received))
            }
            lock.lock(); data = incoming; lock.unlock()
            for offset in stride(from: 0, to: reply.count, by: fragment) {
                let chunk = reply.subdata(in: offset..<min(reply.count, offset + fragment))
                _ = chunk.withUnsafeBytes { Darwin.send(connection, $0.baseAddress, $0.count, 0) }
                usleep(2_000)
            }
        }
    }
    func stop() { _ = Darwin.shutdown(fd, SHUT_RDWR); group.wait(); Darwin.close(fd) }
}
