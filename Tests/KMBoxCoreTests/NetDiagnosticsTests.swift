import XCTest
import Darwin
@testable import KMBoxCore

final class NetDiagnosticsTests: XCTestCase {
    private func connect(_ server: UDPFixture) async throws -> NetClient {
        let client = NetClient()
        _ = try await client.connect(NetConfiguration(host: "127.0.0.1", port: String(server.port), uuid: "12345678", timeout: 0.1))
        return client
    }

    func testConfigurationWireFormatMatchesOfficialCommands() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = try await connect(server)
        _ = try await client.setNetwork(NetNetworkSettings(host: "192.168.2.188", port: "8888"))
        _ = try await client.setVIDPID(vendor: 0x1234, product: 0xabcd)
        _ = try await client.setCurve(NetCurveSettings(enabled: true, curve: .realtimeArm, strength: 73))
        _ = try await client.setCurve(NetCurveSettings(enabled: false, curve: .bezier, strength: 100))
        _ = try await client.setBypass(true)
        _ = try await client.setBypass(false)
        try await client.disconnect()
        let packets = server.packets
        XCTAssertEqual(packets.count, 7)
        XCTAssertEqual(packets[1].subdata(in: 4..<8).hexadecimal, "c0a802bc")
        XCTAssertEqual(packets[1].suffix(2).hexadecimal, "22b8")
        XCTAssertEqual(packets[1].count, 18)
        XCTAssertEqual(packets[2].subdata(in: 4..<8).hexadecimal, "3412cdab")
        XCTAssertEqual(packets[3].subdata(in: 4..<8).hexadecimal, "49000003")
        XCTAssertEqual(try PacketHeader(data: packets[4]).random, 0)
        XCTAssertEqual(try PacketHeader(data: packets[5]).random, 1)
        XCTAssertEqual(try PacketHeader(data: packets[6]).random, 0)
        XCTAssertEqual(try packets.dropFirst().map { try PacketHeader(data: $0).command },
                       [0x1d3d3323, 0xffed3232, 0xbbcdddac, 0xbbcdddac, 0x21223334, 0x21223334])
    }

    func testReadAndWriteParsingPreservesIdentityAndVerifiesReadback() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = try await connect(server)
        let (before, _) = try await client.peripheralInfo()
        XCTAssertEqual(before.vendorID, 0x1234); XCTAssertEqual(before.productID, 0x5678)
        XCTAssertEqual(before.hidID, 0x9abc); XCTAssertEqual(before.deviceID, 0xdef0)
        XCTAssertEqual(before.mouseMode, 2); XCTAssertEqual(before.keyboardMode, 3)
        let (after, receipts) = try await client.setParsing(NetParsingModes(mouse: 32, keyboard: 255))
        XCTAssertEqual(receipts.count, 3); XCTAssertEqual(after.mouseMode, 32); XCTAssertEqual(after.keyboardMode, 255)
        XCTAssertEqual(after.raw.prefix(8), before.raw.prefix(8))
        let packets = server.packets
        XCTAssertEqual(packets[1].suffix(10), Data(repeating: 0, count: 10))
        XCTAssertEqual(packets[3].suffix(10).hexadecimal, "34127856bc9af0de20ff")
        XCTAssertEqual(try PacketHeader(data: packets[3]).random, 1)
        try await client.disconnect()
    }

    func testQueryShortReplyDoesNotContaminateKeyboardStateOrSendReleases() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = try await connect(server); server.mode = .shortInfo
        do { _ = try await client.peripheralInfo(); XCTFail("Short info cannot be success") }
        catch { guard case KMError.timeout = error else { return XCTFail("Wrong failure: \(error)") } }
        let status = await client.status(); XCTAssertFalse(status.uncertain)
        _ = try await client.move(x: 1, y: 0)
        try await client.disconnect()
        XCTAssertEqual(server.packets.count, 3, "Query timeout must not trigger input recovery or retransmit")
    }

    func testConfigurationTimeoutIsReportedWithoutAutomaticRetry() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = try await connect(server); server.mode = .dropSettings
        do { _ = try await client.setBypass(true); XCTFail("Missing acknowledgement") }
        catch { XCTAssertTrue(error.localizedDescription.contains("是否执行未知")) }
        let status = await client.status(); XCTAssertFalse(status.uncertain)
        try await client.disconnect(); XCTAssertEqual(server.packets.count, 2)
    }

    func testParsingReadbackMismatchIsNotSuccess() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = try await connect(server); server.mode = .mismatchParsing
        do { _ = try await client.setParsing(NetParsingModes(mouse: 10, keyboard: 11)); XCTFail("Readback did not change") }
        catch { XCTAssertTrue(error.localizedDescription.contains("已收到写入应答，但未通过回读确认")) }
        try await client.disconnect(); XCTAssertEqual(server.packets.count, 4)
    }

    func testMonitorReceivesOnlyExpectedSourceAndLayoutThenReleasesPort() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = try await connect(server)
        let (port, blocker) = try reserveMonitorPort(); Darwin.close(blocker)
        _ = try await client.startMonitor(port: port)
        try await Task.sleep(nanoseconds: 30_000_000)
        let batch = try await client.readMonitor()
        XCTAssertEqual(batch.records.count, 2)
        let good = try XCTUnwrap(batch.records.first), unknown = try XCTUnwrap(batch.records.last)
        XCTAssertEqual(good.rawHex, "0105fdff0700ffff0202041a0000000000000000")
        XCTAssertEqual(good.sourceIPv4, "127.0.0.1"); XCTAssertEqual(good.sourcePort, server.port)
        XCTAssertEqual(good.listenPort, port); XCTAssertEqual(good.sequence, 1)
        XCTAssertEqual(good.sessionID, unknown.sessionID); XCTAssertEqual(unknown.sequence, 2)
        XCTAssertLessThan(abs(Date().timeIntervalSince1970 - good.receivedAtUnixSeconds), 2)
        XCTAssertLessThanOrEqual(good.monotonicNanoseconds, unknown.monotonicNanoseconds)
        XCTAssertEqual(unknown.rawHex, "000102"); XCTAssertNil(unknown.frame); XCTAssertNotNil(unknown.decodeError)
        let empty = try await client.readMonitor(); XCTAssertTrue(empty.records.isEmpty, "Idle time must not manufacture mouse reports")
        XCTAssertEqual(batch.accepted, 1); XCTAssertEqual(batch.rejected, 1); XCTAssertEqual(batch.lastRejectedLength, 3)
        let frame = try XCTUnwrap(batch.frames.first)
        XCTAssertEqual(frame.buttons, 5); XCTAssertEqual(frame.x, -3); XCTAssertEqual(frame.y, 7)
        XCTAssertEqual(frame.wheel, -1); XCTAssertEqual(frame.keys, [4, 26]); XCTAssertEqual(frame.modifiers, 2)
        try await client.disconnect()
        let commands = try server.packets.map { try PacketHeader(data: $0) }
        XCTAssertEqual(commands.map(\.random).suffix(2), [0xaa550000 | UInt32(port), 0])
        XCTAssertEqual(commands.map(\.command).suffix(2), [0x27388020, 0x27388020])
        let receiver = try NetMonitorReceiver(local: socketAddress("127.0.0.1", port: 0), host: "127.0.0.1", port: port)
        withExtendedLifetime(receiver) {}
    }

    func testMonitorRejectsPacketsFromAnotherDevice() async throws {
        let (port, blocker) = try reserveMonitorPort(); Darwin.close(blocker)
        let receiver = try NetMonitorReceiver(local: socketAddress("127.0.0.1", port: 0), host: "127.0.0.2", port: port)
        let sender = socket(AF_INET, SOCK_DGRAM, 0); defer { Darwin.close(sender) }
        var target = try socketAddress("127.0.0.1", port: port)
        let data = Data(repeating: 0, count: 20)
        let sent = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(sender, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        XCTAssertEqual(sent, 20)
        var batch = try receiver.read()
        let deadline = Date().addingTimeInterval(0.3)
        while batch.rejected == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
            batch = try receiver.read()
        }
        XCTAssertEqual(batch.accepted, 0); XCTAssertEqual(batch.rejected, 1)
        XCTAssertTrue(batch.records.isEmpty, "Do not capture payloads from other devices")
    }

    func testUnacknowledgedMonitorStartStillRequiresAndSendsStop() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = try await connect(server)
        let (port, blocker) = try reserveMonitorPort(); Darwin.close(blocker)
        server.mode = .dropSettings
        do { _ = try await client.startMonitor(port: port); XCTFail("Missing start ACK") } catch {}
        let state = await client.status(); XCTAssertTrue(state.monitorNeedsStop); XCTAssertEqual(state.monitorPort, port)
        server.mode = .normal
        try await client.disconnect()
        XCTAssertEqual(server.packets.count, 3)
        XCTAssertEqual(try PacketHeader(data: server.packets.last!).random, 0)
    }

    func testOccupiedMonitorPortDoesNotSendEnableAndFailedStopRemainsRetryable() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = try await connect(server)
        let (port, blocker) = try reserveMonitorPort()
        do { _ = try await client.startMonitor(port: port); XCTFail("Port occupied") } catch {}
        XCTAssertEqual(server.packets.count, 1)
        Darwin.close(blocker)
        _ = try await client.startMonitor(port: port)
        server.mode = .dropSettings
        do { _ = try await client.stopMonitor(); XCTFail("Stop should be unconfirmed") } catch {}
        let state = await client.status(); XCTAssertTrue(state.monitorNeedsStop); XCTAssertNil(state.monitorPort)
        let receiver = try NetMonitorReceiver(local: socketAddress("127.0.0.1", port: 0), host: "127.0.0.1", port: port)
        withExtendedLifetime(receiver) {}
        server.mode = .normal
        _ = try await client.stopMonitor()
        try await client.disconnect()
        XCTAssertEqual(server.packets.count, 4)
    }

    func testRebootReleasesHeldInputsAndClosesEvenWhenAcknowledgementMissing() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = try await connect(server)
        _ = try await client.setKey(4, down: true)
        server.mode = .dropSettings
        do { _ = try await client.reboot(); XCTFail("Reboot ACK missing") } catch {}
        let state = await client.status(); XCTAssertFalse(state.connected)
        let packets = server.packets
        XCTAssertEqual(try packets.map { try PacketHeader(data: $0).command }, [0xaf3c2828, 0x123c2c2f, 0xffeead38, 0x123c2c2f, 0xaa8855aa])
        XCTAssertEqual(packets[3].suffix(12), Data(repeating: 0, count: 12))
        try await client.disconnect(); XCTAssertEqual(server.packets.count, 5)
    }

    private func reserveMonitorPort() throws -> (UInt16, Int32) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        for port in UInt16(20000)..<UInt16(49000) {
            var address = try socketAddress("127.0.0.1", port: port)
            if withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 { return (port, fd) }
        }
        Darwin.close(fd); throw KMError.io("No fixture monitor port available")
    }
}
