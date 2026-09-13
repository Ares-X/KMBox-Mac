import XCTest
@testable import KMBoxApp
@testable import KMBoxCore

@MainActor
final class AppModelTests: XCTestCase {
    private func waitForBoard(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.boardBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.boardBusy, "Board operation must finish")
    }

    private func waitForNet(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.netBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.netBusy)
    }

    func testPeripheralFailureClearsStaleDisplayAndDisconnectClearsSnapshot() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let model = AppModel(temporarySession: true)
        model.host = "127.0.0.1"; model.port = String(server.port); model.uuid = "1"
        model.connectNet(); try await waitForNet(model)
        let headers = try server.packets.map(PacketHeader.init(data:))
        XCTAssertEqual(headers.map(\.command), [NetCommand.connect.rawValue, NetCommand.peripheral.rawValue])
        XCTAssertEqual(headers.last?.random, 0, "Connection discovery must only read, never write defaults")
        XCTAssertEqual(model.peripheral?.vendorID, 0x1234); XCTAssertNotNil(model.peripheralReadAt)
        server.mode = .shortInfo
        model.readPeripheral(); try await waitForNet(model)
        XCTAssertNil(model.peripheral); XCTAssertNil(model.peripheralReadAt)
        XCTAssertFalse(model.netError.isEmpty); XCTAssertFalse(model.netUncertain)
        server.mode = .normal
        model.readPeripheral(); try await waitForNet(model)
        model.disconnectNet(); try await waitForNet(model)
        XCTAssertNil(model.peripheral); XCTAssertFalse(model.netConnected)
        _ = await model.shutdown()
    }

    func testUnsupportedConfigurationReadKeepsControlConnectionUsable() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        server.mode = .shortInfo
        let model = AppModel(temporarySession: true)
        model.host = "127.0.0.1"; model.port = String(server.port); model.uuid = "1"
        model.connectNet(); try await waitForNet(model)
        XCTAssertTrue(model.netConnected); XCTAssertTrue(model.canControl)
        XCTAssertNil(model.peripheral); XCTAssertNil(model.peripheralReadAt)
        XCTAssertTrue(model.netError.isEmpty, "A successful handshake must remain successful")
        XCTAssertTrue(model.peripheralMessage.contains("读取失败"))
        model.move(2, 3); try await waitForNet(model)
        XCTAssertTrue(model.netError.isEmpty); XCTAssertFalse(model.netUncertain)
        server.mode = .normal
        model.readPeripheral(); try await waitForNet(model)
        XCTAssertEqual(model.peripheral?.vendorID, 0x1234)
        _ = await model.shutdown()
    }

    func testZeroConfigurationReplyIsNotPresentedAsCurrentSettings() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        server.mode = .zeroInfo
        let model = AppModel(temporarySession: true)
        model.host = "127.0.0.1"; model.port = String(server.port); model.uuid = "1"
        model.connectNet(); try await waitForNet(model)
        XCTAssertTrue(model.netConnected); XCTAssertTrue(model.peripheral?.isEmpty == true)
        XCTAssertTrue(model.peripheralMessage.contains("无法确认解析参数"))
        let headers = try server.packets.map(PacketHeader.init(data:))
        XCTAssertEqual(headers.map(\.command), [NetCommand.connect.rawValue, NetCommand.peripheral.rawValue])
        model.disconnectNet(); try await waitForNet(model)
        XCTAssertNil(model.peripheral); XCTAssertNil(model.peripheralReadAt)
        _ = await model.shutdown()
    }

    func testTimedMovementShowsOnlyRequestedEndpointsAndUpdatesSessionStatistics() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let model = AppModel(temporarySession: true)
        model.host = "127.0.0.1"; model.port = String(server.port); model.uuid = "1"
        model.connectNet(); try await waitForNet(model)
        model.timedMove(30, 70, milliseconds: 500); try await waitForNet(model)
        model.timedMove(-10, 20, milliseconds: 500, controls: try NetBezierControls(x1: 10, y1: 20, x2: 30, y2: 40))
        try await waitForNet(model)
        XCTAssertTrue(model.netError.isEmpty)
        XCTAssertEqual(model.sentTrace.count, 3)
        XCTAssertEqual(model.sentTrace.last?.x, 20); XCTAssertEqual(model.sentTrace.last?.y, 90)
        XCTAssertEqual(model.deviceTrace.count, 1, "Requested curves cannot stand in for actual device output")
        XCTAssertEqual(model.netStatistics.sent, 4); XCTAssertEqual(model.netStatistics.acknowledged, 4)
        _ = await model.shutdown()
    }

    func testShutdownWaitsForPendingNetOperationAndThenClosesConnection() async throws {
        let server = try UDPFixture(); defer { server.stop() }
        let model = AppModel(temporarySession: true)
        model.host = "127.0.0.1"; model.port = String(server.port); model.uuid = "1"
        model.connectNet(); try await waitForNet(model)
        var continuation: CheckedContinuation<Void, Never>?
        model.netAction("pending setting") { await withCheckedContinuation { continuation = $0 }; return [] }
        while continuation == nil { await Task.yield() }
        let shutdown = Task { await model.shutdown() }
        await Task.yield()
        XCTAssertTrue(model.netBusy); XCTAssertTrue(model.netConnected)
        continuation?.resume()
        let failures = await shutdown.value
        XCTAssertTrue(failures.isEmpty); XCTAssertFalse(model.netConnected); XCTAssertFalse(model.netBusy)
    }

    func testLateReloadPreservesEditsAndDoesNotReopenClosedDocument() async throws {
        let mock = try MockNB(); defer { mock.stop() }
        try Data("# coding: gbk\nprint('hello')\n".utf8).write(to: mock.root.appendingPathComponent("hello.py"))
        let model = AppModel(temporarySession: true)
        model.serialPath = mock.serial; model.connectBoard()
        try await waitForBoard(model)
        let entry = try XCTUnwrap(model.boardEntries.first { $0.name == "hello.py" })
        model.openBoardEntry(entry); try await waitForBoard(model)
        let original = try XCTUnwrap(model.activeDocument)
        XCTAssertTrue(original.text.hasPrefix("# coding: utf-8"))
        XCTAssertTrue(String(decoding: try XCTUnwrap(original.remoteBaseline), as: UTF8.self).hasPrefix("# coding: gbk"))
        model.openBoardEntry(entry, reload: true)
        model.updateText("# keep this new draft\n")
        try await waitForBoard(model)
        XCTAssertEqual(model.activeDocument?.text, "# keep this new draft\n")
        XCTAssertEqual(model.activeDocument?.remoteBaseline, original.remoteBaseline)
        XCTAssertTrue(model.boardError.contains("编辑内容已变化"))

        model.updateText(original.text)
        model.openBoardEntry(entry, reload: true)
        model.closeDocument(original.id)
        try await waitForBoard(model)
        XCTAssertFalse(model.documents.contains { $0.remotePath == entry.path })
        _ = await model.shutdown()
    }

    func testStopWaitsForPreviousOperationBeforeAcceptingNewWork() async throws {
        let mock = try MockNB(); defer { mock.stop() }
        let model = AppModel(temporarySession: true)
        model.serialPath = mock.serial; model.connectBoard(); try await waitForBoard(model)
        var continuation: CheckedContinuation<Void, Never>?
        model.boardAction("pending operation") { await withCheckedContinuation { continuation = $0 } }
        while continuation == nil { await Task.yield() }
        model.stopBoard()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(model.boardBusy, "Stop must not declare idle while the old action is pending")
        var started = false
        model.boardAction("must wait") { started = true }
        XCTAssertFalse(started)
        continuation?.resume()
        try await waitForBoard(model)
        model.boardAction("next operation") { started = true }
        try await waitForBoard(model)
        XCTAssertTrue(started)
        _ = await model.shutdown()
    }
}
