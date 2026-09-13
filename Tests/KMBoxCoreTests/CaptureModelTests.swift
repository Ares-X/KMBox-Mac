import XCTest
@testable import KMBoxApp

@MainActor
final class CaptureModelTests: XCTestCase {
    private let format = VideoFormat(id: 0, width: 1920, height: 1080, codec: "420v", rates: [30, 60])

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()) {
            guard Date() < deadline else { XCTFail("Discovery did not reach the expected state"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testSlowDiscoveryLeavesMainActorAvailableAndReturningToPageKeepsSelection() async throws {
        let discovery = VideoDiscoveryFixture()
        let model = CaptureModel(discoverSources: { await discovery.discover() })
        model.refreshIfNeeded()
        try await waitUntil { await discovery.calls == 1 }
        XCTAssertTrue(model.busy)
        // These main-actor operations run while the device service is still waiting.
        model.snapshotFormat = .jpeg
        model.refreshIfNeeded()
        model.refresh()
        await discovery.complete([VideoSource(id: "camera", name: "Camera", formats: [format])])
        try await waitUntil { !model.busy }
        model.rate = 30
        model.refreshIfNeeded()
        XCTAssertEqual(model.sourceID, "camera")
        XCTAssertEqual(model.formatID, 0)
        XCTAssertEqual(model.rate, 30)
        XCTAssertEqual(model.snapshotFormat, .jpeg)
        let calls = await discovery.calls
        XCTAssertEqual(calls, 1, "Page reentry must reuse the discovery result")
        await model.shutdown()
    }

    func testExplicitRefreshPreservesValidFormatAndHandlesRemovedDevice() async throws {
        let discovery = VideoDiscoveryFixture()
        let model = CaptureModel(discoverSources: { await discovery.discover() })
        let otherFormat = VideoFormat(id: 1, width: 1280, height: 720, codec: "420v", rates: [30, 60])
        let source = VideoSource(id: "camera", name: "Camera", formats: [format, otherFormat])
        model.refresh()
        try await waitUntil { await discovery.calls == 1 }
        await discovery.complete([source])
        try await waitUntil { !model.busy }
        model.formatID = 1; model.rate = 30
        model.refresh()
        try await waitUntil { await discovery.calls == 2 }
        await discovery.complete([source])
        try await waitUntil { !model.busy }
        XCTAssertEqual(model.formatID, 1); XCTAssertEqual(model.rate, 30)
        model.refresh()
        try await waitUntil { await discovery.calls == 3 }
        await discovery.complete([])
        try await waitUntil { !model.busy }
        XCTAssertTrue(model.sources.isEmpty); XCTAssertTrue(model.formats.isEmpty)
        XCTAssertEqual(model.sourceID, ""); XCTAssertEqual(model.formatID, -1)
        await model.shutdown()
    }

    func testShutdownDiscardsLateDiscoveryResult() async throws {
        let discovery = VideoDiscoveryFixture()
        let model = CaptureModel(discoverSources: { await discovery.discover() })
        model.refresh()
        try await waitUntil { await discovery.calls == 1 }
        await model.shutdown()
        await discovery.complete([VideoSource(id: "late", name: "Late camera", formats: [format])])
        // Let the cancelled operation return from the device service.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(model.busy); XCTAssertTrue(model.sources.isEmpty)
        XCTAssertEqual(model.sourceID, "")
    }
}

private actor VideoDiscoveryFixture {
    private var pending: CheckedContinuation<[VideoSource], Never>?
    private(set) var calls = 0

    func discover() async -> [VideoSource] {
        calls += 1
        return await withCheckedContinuation { pending = $0 }
    }
    func complete(_ sources: [VideoSource]) {
        pending?.resume(returning: sources); pending = nil
    }
}
