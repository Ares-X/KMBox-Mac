import XCTest
import Darwin
@testable import KMBoxCore

final class FirmwareTests: XCTestCase {
    private func archive(extraName: String? = nil, badChecksum: Bool = false) -> Data {
        var output = Data()
        func entry(_ name: String, _ body: Data) {
            let nameData = Data(name.utf8) + Data([0])
            let fields: [UInt32] = [1, 0x81a4, 0, 0, 1, 0, UInt32(body.count), 0, 0, 0, 0,
                                    UInt32(nameData.count), body.reduce(0) { $0 &+ UInt32($1) } &+ (badChecksum ? 1 : 0)]
            output.append(Data(("070702" + fields.map { String(format: "%08x", $0) }.joined()).utf8))
            output.append(nameData)
            while output.count % 4 != 0 { output.append(0) }
            output.append(body)
            while output.count % 4 != 0 { output.append(0) }
        }
        entry("ota_info.bin", Data(repeating: 1, count: 512))
        entry("d21x_os.itb", Data("fixture-only-kmboxNB".utf8))
        entry("rodata.fatfs", Data((0..<20000).map { UInt8(truncatingIfNeeded: $0) }))
        entry("data.fatfs", Data([3, 4, 5]))
        if let extraName { entry(extraName, Data([7])) }
        entry("TRAILER!!!", Data())
        return output
    }

    func testFirmwareRejectsCorruptionTruncationWrongLayoutAndDuplicates() throws {
        let good = archive()
        XCTAssertEqual(try NBFirmware(data: good).data, good)
        XCTAssertThrowsError(try NBFirmware(data: archive(badChecksum: true)))
        XCTAssertThrowsError(try NBFirmware(data: good.dropLast(20)))
        XCTAssertThrowsError(try NBFirmware(data: archive(extraName: "../elsewhere")))
        XCTAssertThrowsError(try NBFirmware(data: archive(extraName: "data.fatfs")))
        XCTAssertThrowsError(try NBFirmware(data: good + Data([1])))
        XCTAssertThrowsError(try NBFirmware(data: Data(repeating: 0, count: 256)))
        for index in [1, 6, 11, 12] {
            for signed in ["-0000001", "+0000001"] {
                var malformed = good
                let start = 6 + index * 8
                malformed.replaceSubrange(start..<start + 8, with: Data(signed.utf8))
                XCTAssertThrowsError(try NBFirmware(data: malformed))
            }
        }
    }

    func testFirmwareSnapshotDoesNotFollowLaterFileChanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cpio")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = archive(); try original.write(to: url)
        let firmware = try NBFirmware(url: url)
        try Data("replaced after selection".utf8).write(to: url)
        XCTAssertEqual(firmware.data, original)
    }

    func testHTTPWorksWithoutKnowingDeviceAddress() async throws {
        let firmware = try NBFirmware(data: archive())
        let server = FirmwareServer(); defer { server.stop() }
        for peer: String? in [nil, ""] {
            let port = try server.start(firmware: firmware, localAddress: "127.0.0.1", deviceAddress: peer, port: 0)
            let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/kmboxNB.cpio")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(data, firmware.data)
            server.stop()
        }
    }

    func testHTTPDownloadHeadMissingPathRangeAndRestart() async throws {
        let firmware = try NBFirmware(data: archive())
        let server = FirmwareServer(); defer { server.stop() }
        let port = try server.start(firmware: firmware, localAddress: "127.0.0.1", deviceAddress: "127.0.0.1", port: 0)
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        func request(_ path: String, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
            req.httpMethod = method; req.timeoutInterval = 3
            if let range { req.setValue(range, forHTTPHeaderField: "Range") }
            let (body, response) = try await session.data(for: req)
            return (body, response as! HTTPURLResponse)
        }
        let head = try await request("/kmboxNB.cpio", method: "HEAD")
        XCTAssertEqual(head.1.statusCode, 200); XCTAssertTrue(head.0.isEmpty)
        XCTAssertEqual(head.1.value(forHTTPHeaderField: "Content-Length"), String(firmware.data.count))
        XCTAssertEqual(server.status().completedDownloads, 0)
        let get = try await request("/kmboxNB.cpio")
        XCTAssertEqual(get.0, firmware.data); XCTAssertEqual(get.1.statusCode, 200)
        let missing = try await request("/session.json")
        XCTAssertEqual(missing.1.statusCode, 404)
        let post = try await request("/kmboxNB.cpio", method: "POST")
        XCTAssertEqual(post.1.statusCode, 405)
        let range = try await request("/kmboxNB.cpio", range: "bytes=5-")
        XCTAssertEqual(range.1.statusCode, 200); XCTAssertEqual(range.0, firmware.data)
        XCTAssertEqual(server.status().completedDownloads, 2)
        XCTAssertFalse(server.status().message.contains("刷写成功"))
        server.stop(); XCTAssertFalse(server.status().active)
        XCTAssertEqual(try server.start(firmware: firmware, localAddress: "127.0.0.1", deviceAddress: "127.0.0.1", port: port), port)
    }

    func testServerRejectsOtherPeersAndWildcardBinding() async throws {
        let firmware = try NBFirmware(data: archive())
        let server = FirmwareServer(); defer { server.stop() }
        XCTAssertThrowsError(try server.start(firmware: firmware, localAddress: "0.0.0.0", deviceAddress: "127.0.0.1", port: 0))
        XCTAssertThrowsError(try server.start(firmware: firmware, localAddress: "192.0.2.88", deviceAddress: "127.0.0.1", port: 0))
        let port = try server.start(firmware: firmware, localAddress: "127.0.0.1", deviceAddress: "127.0.0.2", port: 0)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/kmboxNB.cpio")!)
        req.timeoutInterval = 2
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        do { _ = try await session.data(for: req); XCTFail("Other peer must not receive firmware") } catch {}
        XCTAssertEqual(server.status().completedDownloads, 0)
        XCTAssertEqual(server.status().bytesSent, 0)
    }

    func testStopInterruptsAnIncompleteRequestAndReleasesPort() throws {
        let server = FirmwareServer(); defer { server.stop() }
        let port = try server.start(firmware: NBFirmware(data: archive()), localAddress: "127.0.0.1", deviceAddress: "127.0.0.1", port: 0)
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { Darwin.close(fd) }
        var address = try socketAddress("127.0.0.1", port: port)
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        } }, 0)
        let partial = Data("GET /kmboxNB.cpio HTTP/1.0\r\n".utf8)
        _ = partial.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        let start = Date(); server.stop()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertFalse(server.status().active)
        XCTAssertEqual(server.status().completedDownloads, 0)
    }

    func testModelCapabilitiesKeepDifferentTransportsAndFirmwareSeparate() {
        XCTAssertTrue(DeviceModel.netPro.supportsNet)
        XCTAssertTrue(DeviceModel.nvideo.supportsNet)
        XCTAssertTrue(DeviceModel.bPro.supportsSerialREPL)
        XCTAssertFalse(DeviceModel.bPro.supportsNet)
        XCTAssertFalse(DeviceModel.net.supportsSerialREPL)
        XCTAssertFalse(DeviceModel.a.supportsNet)
        XCTAssertFalse(DeviceModel.ai.supportsSerialREPL)
        XCTAssertEqual(DeviceModel.allCases.filter(\.supportsFirmwareHosting), [.nb])
    }
}
