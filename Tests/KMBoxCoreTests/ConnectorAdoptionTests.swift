import XCTest
@testable import KMBoxCore

final class ConnectorAdoptionTests: XCTestCase {
    func testTimedMovesMatchOfficialWirePreserveButtonsAndDoNotLeakControlPoints() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = NetClient()
        _ = try await client.connect(NetConfiguration(host: "127.0.0.1", port: String(server.port), uuid: "12345678", timeout: 0.1))
        _ = try await client.setMouseButton(1, down: true)
        let movement = try NetTimedMovement(x: -30, y: 70, milliseconds: 500)
        let controls = try NetBezierControls(x1: -10, y1: 20, x2: 30, y2: -40)
        _ = try await client.moveBezier(movement, controls: controls)
        _ = try await client.moveAutomatically(movement)
        _ = try await client.move(x: 1, y: 2)
        try await client.disconnect()
        let packets = server.packets
        XCTAssertEqual(try PacketHeader(data: packets[2]).command, 0xa238455a)
        XCTAssertEqual(try PacketHeader(data: packets[3]).command, 0xaede7346)
        for packet in packets[2...3] {
            XCTAssertEqual(packet.count, 72)
            XCTAssertEqual(packet.subdata(in: 4..<8).hexadecimal, "f4010000")
            XCTAssertEqual(packet.subdata(in: 16..<32).hexadecimal, "01000000e2ffffff4600000000000000")
        }
        XCTAssertEqual(packets[2].subdata(in: 32..<48).hexadecimal, "f6ffffff140000001e000000d8ffffff")
        XCTAssertEqual(packets[2].suffix(24), Data(repeating: 0, count: 24))
        for packet in packets[3...4] { XCTAssertEqual(packet.suffix(40), Data(repeating: 0, count: 40)) }
        XCTAssertEqual(packets[5].suffix(56), Data(repeating: 0, count: 56), "Disconnect releases the previously held button")
    }

    func testTimedResponseWaitIncludesRequestedDurationWithoutRetrying() async throws {
        let server = try UDPFixture(); defer { server.stop() }; server.mode = .delayedTimedMove
        let client = NetClient()
        _ = try await client.connect(NetConfiguration(host: "127.0.0.1", port: String(server.port), uuid: "1", timeout: 0.05))
        let receipt = try await client.moveAutomatically(NetTimedMovement(x: 1, y: 0, milliseconds: 200))
        XCTAssertGreaterThan(receipt.milliseconds, 100)
        XCTAssertEqual(server.packets.count, 2)
        try await client.disconnect()
    }

    func testTimedMoveTimeoutUsesExistingUncertainInputRecovery() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = NetClient()
        _ = try await client.connect(NetConfiguration(host: "127.0.0.1", port: String(server.port), uuid: "1", timeout: 0.05))
        server.mode = .dropMove
        do { _ = try await client.moveAutomatically(NetTimedMovement(x: 1, y: 0, milliseconds: 1)); XCTFail("Expected missing ACK") }
        catch { guard case KMError.uncertain = error else { return XCTFail("Wrong error: \(error)") } }
        do { _ = try await client.move(x: 1, y: 0); XCTFail("State must remain uncertain") } catch {}
        let stats = await client.statistics()
        XCTAssertEqual(stats.sent, 2); XCTAssertEqual(stats.timeouts, 1); XCTAssertEqual(stats.acknowledged, 1)
        XCTAssertEqual(server.packets.count, 2)
        server.mode = .normal; try await client.disconnect()
    }

    func testInvalidTimedMovementCannotBeConstructed() throws {
        for ms in [Int.min, -1, 0, 10001, Int.max] { XCTAssertThrowsError(try NetTimedMovement(x: 0, y: 0, milliseconds: ms)) }
        XCTAssertThrowsError(try NetTimedMovement(x: 32768, y: 0, milliseconds: 1))
        XCTAssertThrowsError(try NetBezierControls(x1: 0, y1: 0, x2: 0, y2: -32769))
        _ = try NetTimedMovement(x: -32768, y: 32767, milliseconds: 10000)
    }

    func testStatisticsCountOnlySentTransactionsAndMatchingResponsesAcrossFailures() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let client = NetClient()
        server.mode = .staleThenCorrect
        _ = try await client.connect(NetConfiguration(host: "127.0.0.1", port: String(server.port), uuid: "1", timeout: 0.05))
        server.mode = .shortThenCorrect
        _ = try await client.move(x: 1, y: 0)
        do { _ = try await client.move(x: 40000, y: 0); XCTFail() } catch {}
        server.mode = .shortInfo
        do { _ = try await client.peripheralInfo(); XCTFail() } catch {}
        let stats = await client.statistics()
        XCTAssertEqual(stats.sent, 3); XCTAssertEqual(stats.acknowledged, 2); XCTAssertEqual(stats.timeouts, 1)
        XCTAssertEqual(stats.ignoredResponses, 3); XCTAssertEqual(stats.bytesSent, 16 + 72 + 26)
        XCTAssertEqual(stats.receiveFailures, 0)
        try await client.disconnect()
        let retained = await client.statistics(); XCTAssertEqual(retained, stats)
        await client.clearStatistics()
        let cleared = await client.statistics(); XCTAssertEqual(cleared, NetTransactionStatistics())
        XCTAssertEqual(server.packets.count, 3, "Inspecting/resetting statistics must not send any probes or releases")
    }

    func testStatisticsVarianceAndNewConnectionReset() async throws {
        var stats = NetTransactionStatistics()
        for value in [2.0, 4.0, 6.0] { stats.didSend(bytes: 16); stats.didAcknowledge(milliseconds: value, ignored: 0) }
        XCTAssertEqual(stats.meanMilliseconds, 4); XCTAssertEqual(stats.minimumMilliseconds, 2); XCTAssertEqual(stats.maximumMilliseconds, 6)
        XCTAssertEqual(try XCTUnwrap(stats.standardDeviationMilliseconds), sqrt(8.0 / 3), accuracy: 1e-12)
        let server = try UDPFixture(); defer { server.stop() }
        let client = NetClient(), config = try NetConfiguration(host: "127.0.0.1", port: String(server.port), uuid: "1", timeout: 0.05)
        server.mode = .dropAll
        do { _ = try await client.connect(config); XCTFail() } catch {}
        let failed = await client.statistics(); XCTAssertEqual(failed.timeouts, 1)
        server.mode = .normal; _ = try await client.connect(config)
        let connected = await client.statistics(); XCTAssertEqual(connected.sent, 1); XCTAssertEqual(connected.timeouts, 0)
        try await client.disconnect()
    }

    private func record(_ sequence: UInt64, bytes: Int = 20) -> NetMonitorRecord {
        NetMonitorRecord(data: Data(repeating: 7, count: bytes), sessionID: UUID(), sequence: sequence,
                         receivedAt: Date(timeIntervalSince1970: 1_000.125), monotonicNanoseconds: 123456789,
                         sourceIPv4: "127.0.0.1", sourcePort: 8888, listenPort: 6688)
    }

    func testMonitorSnapshotExportPreservesRawUnknownFormatsAndFractionalTimestamps() throws {
        var capture = NetMonitorCapture(); capture.append([record(1), record(2, bytes: 4096)])
        let lines = try capture.jsonLines().split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0]["retainedRecords"] as? Int, 2); XCTAssertEqual(lines[0]["discardedRecords"] as? Int, 0)
        XCTAssertEqual(lines[1]["receivedAtUnixSeconds"] as? Double, 1_000.125)
        XCTAssertEqual(lines[1]["monotonicNanoseconds"] as? UInt64, 123456789)
        XCTAssertEqual(lines[2]["rawHex"] as? String, String(repeating: "07", count: 4096))
        XCTAssertNil(lines[2]["frame"]); XCTAssertNotNil(lines[2]["decodeError"])
    }

    func testMonitorSnapshotEvictionReportsLossAndRetainsNewestRecords() throws {
        var capture = NetMonitorCapture()
        capture.append((0..<10003).map { record(UInt64($0)) })
        XCTAssertEqual(capture.records.count, 10000); XCTAssertEqual(capture.discardedRecords, 3)
        XCTAssertEqual(capture.records.first?.sequence, 3); XCTAssertEqual(capture.records.last?.sequence, 10002)
        capture = NetMonitorCapture()
        capture.append((0..<130).map { record(UInt64($0), bytes: 65_000) })
        XCTAssertLessThanOrEqual(capture.records.count * 65_000, NetMonitorCapture.maximumRawBytes)
        XCTAssertEqual(capture.discardedRecords + UInt64(capture.records.count), 130)
        XCTAssertEqual(capture.records.last?.sequence, 129)
    }
}
