import XCTest
import Darwin
@testable import KMBoxApp
@testable import KMBoxCore

@MainActor
final class MonitorModelTests: XCTestCase {
    func testReportsDriveDeviceTraceWithoutInventingRequestsOrIdleMovement() async throws {
        let model = AppModel(temporarySession: true)
        model.monitorListening = true
        XCTAssertEqual(model.monitorReceptionState, .waiting)
        let time = Date()
        func record(_ sequence: UInt64, _ bytes: [UInt8]) -> NetMonitorRecord {
            NetMonitorRecord(data: Data(bytes), sessionID: UUID(), sequence: sequence,
                             receivedAt: time, monotonicNanoseconds: sequence,
                             sourceIPv4: "127.0.0.1", sourcePort: 8888, listenPort: 6688)
        }
        let short = record(1, [0, 1, 2])
        model.consumeMonitorBatch(NetMonitorBatch(records: [short], received: 1, undecodable: 1, foreignSource: 0, extended: 0,
                                                   accepted: 0, rejected: 1, lastRejectedLength: 3,
                                                   lastReceivedAt: time, lastReceivedLength: 3))
        XCTAssertEqual(model.monitorReceptionState, .undecodable)
        XCTAssertEqual(model.deviceTrace, [.zero])
        // Report IDs can be zero on the real NB. Signed deltas belong to the device stream.
        let move = record(2, [0, 0, 0xfd, 0xff, 7, 0, 0, 0] + Array(repeating: 0, count: 12) + [0xab, 0xcd])
        let stationary = record(3, Array(repeating: 0, count: 20))
        let batch = NetMonitorBatch(records: [move, stationary], received: 3, undecodable: 1, foreignSource: 0, extended: 1,
                                    accepted: 2, rejected: 1, lastRejectedLength: 3,
                                    lastReceivedAt: time, lastReceivedLength: 20)
        model.consumeMonitorBatch(batch)
        XCTAssertEqual(model.monitorReceptionState, .receiving)
        XCTAssertEqual(model.deviceTrace, [.zero, CGPoint(x: -3, y: 7)])
        XCTAssertEqual(model.sentTrace, [.zero], "Device movement must not populate this app's requested endpoints")
        XCTAssertEqual(model.monitorCapture.records.count, 3)
        XCTAssertEqual(model.monitorLastReceivedAt, time)
        XCTAssertEqual(model.monitorExtended, 1)
        let idle = NetMonitorBatch(records: [], received: 3, undecodable: 1, foreignSource: 0, extended: 1,
                                   accepted: 2, rejected: 1, lastRejectedLength: 3,
                                   lastReceivedAt: time, lastReceivedLength: 20)
        model.clearTraces(); model.consumeMonitorBatch(idle)
        XCTAssertEqual(model.deviceTrace, [.zero], "An idle poll must not replay the previous movement after clearing")
        XCTAssertEqual(model.monitorCapture.records.count, 3, "Clearing traces keeps the original capture available")
        model.monitorReadError = "test receive failure"
        XCTAssertEqual(model.monitorReceptionState, .failed)
        model.monitorListening = false
        XCTAssertEqual(model.monitorReceptionState, .stopped)
        _ = await model.shutdown()
    }

    func testLiveReceiverLifecycleUpdatesTraceAndRestartResetsReception() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let model = AppModel(temporarySession: true)
        model.host = "127.0.0.1"; model.port = String(server.port); model.uuid = "1"
        model.connectNet(); try await waitForNet(model)
        let port = try availablePort()
        model.beginMonitor(port: String(port)); try await waitForNet(model)
        let deadline = Date().addingTimeInterval(2)
        while model.monitorReceived < 2 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.monitorReceived, 2)
        XCTAssertEqual(model.monitorAccepted, 1); XCTAssertEqual(model.monitorUndecodable, 1)
        XCTAssertEqual(model.deviceTrace.last, CGPoint(x: -3, y: 7))
        XCTAssertEqual(model.monitorEndpoint, "127.0.0.1:\(port)")
        model.monitorReadError = "test receive failure"
        XCTAssertEqual(model.monitorReceptionState, .failed)
        model.endMonitor(); try await waitForNet(model)
        XCTAssertFalse(model.monitorListening); XCTAssertFalse(model.monitorNeedsStop)
        XCTAssertEqual(model.monitorReceptionState, .stopped)
        XCTAssertEqual(model.monitorReadError, "test receive failure", "Stopping retains the previous error as evidence")
        XCTAssertEqual(model.monitorCapture.records.count, 2)
        model.beginMonitor(port: String(port)); try await waitForNet(model)
        XCTAssertTrue(model.monitorReadError.isEmpty)
        let restartDeadline = Date().addingTimeInterval(2)
        while model.monitorReceived < 2 && Date() < restartDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.monitorReceived, 2, "A new monitoring session resets cumulative counts")
        XCTAssertEqual(model.deviceTrace, [.zero, CGPoint(x: -3, y: 7)])
        model.disconnectNet(); try await waitForNet(model)
        XCTAssertFalse(model.monitorListening); XCTAssertTrue(model.monitorEndpoint.isEmpty)
        _ = await model.shutdown()
    }

    private func waitForNet(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.netBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.netBusy); XCTAssertTrue(model.netError.isEmpty, model.netError)
    }

    private func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0); defer { Darwin.close(fd) }
        for port in UInt16(20000)..<UInt16(49000) {
            var address = try socketAddress("127.0.0.1", port: port)
            if withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            } }) == 0 { return port }
        }
        throw KMError.io("No fixture monitor port available")
    }
}
