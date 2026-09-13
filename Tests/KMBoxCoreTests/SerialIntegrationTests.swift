import XCTest
import Darwin
@testable import KMBoxCore

final class MockNB {
    let process = Process()
    private let exited = DispatchSemaphore(value: 0)
    let folder: URL
    let root: URL
    let serial: String
    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("km-tests-" + UUID().uuidString)
        root = folder.appendingPathComponent("board")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let info = folder.appendingPathComponent("info.json")
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [package.appendingPathComponent("tools/mock_nb.py").path, "--info", info.path, "--root", root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        let completion = exited
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !FileManager.default.fileExists(atPath: info.path), process.isRunning,
              DispatchTime.now().uptimeNanoseconds < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard let data = try? Data(contentsOf: info), let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = config["serial"] as? String else {
            process.terminate(); throw KMError.io("模拟设备未启动")
        }
        serial = path
    }
    func stop() {
        if process.isRunning { process.terminate() }
        if exited.wait(timeout: .now() + 3) == .timedOut, kill(process.processIdentifier, 0) == 0 {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
        }
        try? FileManager.default.removeItem(at: folder)
    }
}

final class SerialIntegrationTests: XCTestCase {
    func testFailedUploadClosesDeviceFileAndPreservesOriginal() async throws {
        let mock = try MockNB(); defer { mock.stop() }
        let client = SerialREPL()
        _ = try await client.connect(path: mock.serial)
        let path = mock.root.path + "/hello.py", original = try await client.readFile(path)
        _ = try await client.execute("""
        import ubinascii
        _saved_unhex = ubinascii.unhexlify
        _decode_calls = 0
        def _fail_second(value):
            global _decode_calls
            _decode_calls += 1
            if _decode_calls == 2:
                raise OSError('test write interruption')
            return _saved_unhex(value)
        ubinascii.unhexlify = _fail_second
        """)
        do {
            _ = try await client.upload(Data(repeating: 65, count: 1000), to: path, expected: original)
            XCTFail("Injected failure must abort upload")
        } catch { XCTAssertTrue(error.localizedDescription.contains("test write interruption")) }
        let closed = try await client.execute("print(_km_upload.closed)")
        XCTAssertEqual(closed, "True\n")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        try await client.disconnect()
    }

    func testInvalidExecutionTimeoutDoesNotStartCode() async throws {
        let mock = try MockNB(); defer { mock.stop() }
        let client = SerialREPL()
        _ = try await client.connect(path: mock.serial)
        for timeout in [Double.nan, Double.infinity, -1, 0] {
            do { _ = try await client.execute("raise RuntimeError('must not run')", timeout: timeout); XCTFail("Invalid timeout") }
            catch { guard case KMError.invalid = error else { return XCTFail("Wrong error: \(error)") } }
        }
        let result = try await client.execute("print(42)")
        XCTAssertEqual(result, "42\n")
        try await client.disconnect()
    }
    func testPTYConnectReadWriteVerifyBackupAndConcurrentConflict() async throws {
        let mock = try MockNB(); defer { mock.stop() }
        let client = SerialREPL()
        _ = try await client.connect(path: mock.serial)
        let root = await client.workingDirectory
        XCTAssertEqual(URL(fileURLWithPath: root).resolvingSymlinksInPath(), mock.root.resolvingSymlinksInPath())
        let original = try await client.readFile(root + "/hello.py")
        let replacement = Data("# 汉字与引号 ' \" \\ \nprint('changed')\n".utf8)
        let result = try await client.upload(replacement, to: root + "/hello.py", expected: original)
        XCTAssertEqual(try Data(contentsOf: mock.root.appendingPathComponent("hello.py")), replacement)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.backupPath!)), original)
        let changedByOther = Data("print('external change')\n".utf8)
        try changedByOther.write(to: mock.root.appendingPathComponent("hello.py"))
        do {
            _ = try await client.upload(replacement, to: root + "/hello.py", expected: replacement)
            XCTFail("External edits must not be overwritten")
        } catch { guard case KMError.conflict = error else { return XCTFail("Wrong conflict: \(error)") } }
        XCTAssertEqual(try Data(contentsOf: mock.root.appendingPathComponent("hello.py")), changedByOther)
        try await client.disconnect()
    }

    func testPTYFileLifecycleAndStartupBackup() async throws {
        let mock = try MockNB(); defer { mock.stop() }
        let client = SerialREPL()
        _ = try await client.connect(path: mock.serial)
        let root = await client.workingDirectory
        try await client.createDirectory(root + "/scripts")
        let source = Data("print('test')\n".utf8)
        _ = try await client.upload(source, to: root + "/scripts/a.py", expected: nil)
        try await client.rename(root + "/scripts/a.py", to: root + "/scripts/b.py")
        let entries = try await client.list(root + "/scripts")
        XCTAssertEqual(entries.map(\.name), ["b.py"])
        let previousMain = Data("print('old startup')\n".utf8)
        try previousMain.write(to: mock.root.appendingPathComponent("main.py"))
        let startup = try await client.setStartupScript(root + "/scripts/b.py", expectedMain: previousMain)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: startup.backupPath!)), previousMain)
        let output = try await client.execute("exec(open(\(SerialREPL.pythonString(root + "/main.py"))).read())")
        XCTAssertEqual(output, "test\n")
        try await client.remove(root + "/scripts/b.py", directory: false)
        try await client.remove(root + "/scripts", directory: true)
        let exists = try await client.fileExists(root + "/scripts")
        XCTAssertFalse(exists)
        try await client.disconnect()
    }

    func testPTYScriptOutputErrorAndStopWithReusableConnection() async throws {
        let mock = try MockNB(); defer { mock.stop() }
        let client = SerialREPL()
        _ = try await client.connect(path: mock.serial)
        let output = try await client.execute("print('你好 🌏')")
        XCTAssertEqual(output, "你好 🌏\n")
        do { _ = try await client.execute("raise ValueError('expected-test-error')"); XCTFail("Must report board exception") }
        catch { XCTAssertTrue(error.localizedDescription.contains("expected-test-error")) }
        try await client.begin("import time\nwhile True:\n    print('tick')\n    time.sleep(0.02)")
        try await Task.sleep(nanoseconds: 100_000_000)
        let stopped = try await client.stop()
        XCTAssertTrue(stopped.completed)
        XCTAssertTrue(String(decoding: stopped.output, as: UTF8.self).contains("tick"))
        XCTAssertTrue(String(decoding: stopped.error, as: UTF8.self).contains("KeyboardInterrupt"))
        let reused = try await client.execute("print(6 * 7)")
        XCTAssertEqual(reused, "42\n")
        try await client.disconnect()
    }

    func testPTYSyntaxCheckDoesNotExecuteAndCreateOnlyPreservesExistingFile() async throws {
        let mock = try MockNB(); defer { mock.stop() }
        let client = SerialREPL()
        _ = try await client.connect(path: mock.serial)
        _ = try await client.syntaxCheck("raise RuntimeError('must not execute')", filename: "test.py")
        do { _ = try await client.syntaxCheck("if :", filename: "bad.py"); XCTFail("Invalid syntax") }
        catch { XCTAssertTrue(error.localizedDescription.contains("SyntaxError")) }
        do { _ = try await client.upload(Data(), to: mock.root.path + "/hello.py", expected: nil); XCTFail("Must refuse existing path") }
        catch { guard case KMError.conflict = error else { return XCTFail("Unexpected \(error)") } }
        try await client.disconnect()
    }

    func testPTYInteractiveExpressionAndInputPrompt() async throws {
        let mock = try MockNB(); defer { mock.stop() }
        let client = SerialREPL()
        _ = try await client.connect(path: mock.serial)
        try await client.beginInteractive("6 * 7")
        var result = Data()
        for _ in 0..<100 {
            let chunk = try await client.pollOutput(); result.append(chunk.output)
            if chunk.completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "42\n")
        try await client.begin("print('name=' + input('Enter name: '))")
        try await client.sendInput("Mac用户")
        result = Data()
        var completed = false
        for _ in 0..<100 {
            let chunk = try await client.pollOutput(); result.append(chunk.output)
            if chunk.completed { completed = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(completed)
        XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("name=Mac用户"))
        try await client.disconnect()
    }

    func testLargeFileReadKeepsDeviceAllocationsBounded() async throws {
        let mock = try MockNB(); defer { mock.stop() }
        let file = mock.root.appendingPathComponent("large.bin")
        let bytes = Data((0..<16001).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: file)
        let client = SerialREPL()
        _ = try await client.connect(path: mock.serial)
        _ = try await client.execute("""
        import builtins
        _test_open = builtins.open
        class LimitedFile:
            def __init__(self, *args): self.file = _test_open(*args)
            def __enter__(self): return self
            def __exit__(self, *args): self.file.close()
            def seek(self, *args): return self.file.seek(*args)
            def read(self, size=-1):
                if size < 0 or size > 1024: raise MemoryError('bounded device heap')
                return self.file.read(size)
        open = LimitedFile
        """)
        let received = try await client.readFile(file.path)
        XCTAssertEqual(received, bytes)
        try await client.disconnect()
    }

    func testPTYRunDeviceFileHandlesBOMWithoutRewritingTheFile() async throws {
        let mock = try MockNB(); defer { mock.stop() }
        let file = mock.root.appendingPathComponent("bom.py")
        let data = Data([0xef, 0xbb, 0xbf]) + Data("print('BOM works')\n".utf8)
        try data.write(to: file)
        let client = SerialREPL()
        _ = try await client.connect(path: mock.serial)
        try await client.beginFile(file.path)
        var output = Data(), error = Data(), completed = false
        for _ in 0..<100 {
            let chunk = try await client.pollOutput(); output.append(chunk.output); error.append(chunk.error)
            if chunk.completed { completed = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(completed)
        XCTAssertTrue(error.isEmpty)
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "BOM works\n")
        XCTAssertEqual(try Data(contentsOf: file), data)
        try await client.disconnect()
    }
}
