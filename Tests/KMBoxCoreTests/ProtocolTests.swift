import XCTest
@testable import KMBoxCore

final class ProtocolTests: XCTestCase {
    func testHeaderMatchesPublishedWindowsLayout() throws {
        let header = PacketHeader(uuid: 0x12345678, random: 0x11223344, sequence: 1, command: NetCommand.move.rawValue)
        XCTAssertEqual(header.data.hexadecimal, "7856341244332211010000004573deae")
        XCTAssertEqual(try PacketHeader(data: header.data), header)
        let data = MouseState().payload(x: -1, y: 256)
        XCTAssertEqual(data.count, 56)
        XCTAssertEqual(data.prefix(16).hexadecimal, "00000000ffffffff0001000000000000")
        XCTAssertEqual((header.data + data).count, 72)
    }

    func testKeyboardPreservesModifiersAndHeldKeys() throws {
        var state = KeyboardState()
        try state.set(0xe3, down: true)
        try state.set(4, down: true)
        try state.set(5, down: true)
        try state.set(4, down: false)
        XCTAssertEqual(state.payload.hexadecimal, "080005000000000000000000")
        try state.set(0xe3, down: false)
        XCTAssertEqual(state.modifiers, 0)
    }

    func testKeyboardOverflowDoesNotSilentlyDropHeldKeys() throws {
        var state = KeyboardState()
        for key in UInt8(4)...UInt8(13) { try state.set(key, down: true) }
        XCTAssertThrowsError(try state.set(14, down: true))
        XCTAssertEqual(state.keys, Array(UInt8(4)...UInt8(13)))
    }

    func testConfigValidation() throws {
        XCTAssertEqual(try NetConfiguration(host: "127.0.0.1", port: "6234", uuid: "0x0012abcd").uuid, 0x12abcd)
        XCTAssertThrowsError(try NetConfiguration(host: "999.2.3.4", port: "6234", uuid: "12345678"))
        XCTAssertThrowsError(try NetConfiguration(host: "127.0.0.1", port: "0", uuid: "12345678"))
        XCTAssertThrowsError(try NetConfiguration(host: "127.0.0.1", port: "6234", uuid: "123456789"))
    }

    func testRawREPLHandlesArbitraryChunkBoundaries() throws {
        let output = Data("你好\n".utf8)
        let errors = Data("ValueError\n".utf8)
        let wire = output + Data([4]) + errors + Data([4, 62])
        for size in 1...wire.count {
            var parser = RawREPLDecoder()
            var received = Data(), receivedError = Data(), completed = false
            for start in stride(from: 0, to: wire.count, by: size) {
                let chunk = try parser.feed(Data(wire[start..<min(start + size, wire.count)]))
                received.append(chunk.output); receivedError.append(chunk.error); completed = chunk.completed
            }
            XCTAssertEqual(received, output); XCTAssertEqual(receivedError, errors); XCTAssertTrue(completed)
        }
    }
}
