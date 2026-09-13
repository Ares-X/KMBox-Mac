import Foundation

public struct REPLChunk: Sendable {
    public var output = Data()
    public var error = Data()
    public var completed = false
    public init() {}

}

/// Streaming raw REPL framing preserves split UTF-8 by returning bytes to the consumer.
public struct RawREPLDecoder: Sendable {
    private var stage = 0
    public init() {}
    public mutating func feed(_ data: Data) throws -> REPLChunk {
        var result = REPLChunk()
        for byte in data {
            switch stage {
            case 0:
                if byte == 4 { stage = 1 } else { result.output.append(byte) }
            case 1:
                if byte == 4 { stage = 2 } else { result.error.append(byte) }
            case 2:
                if byte == 62 { stage = 3; result.completed = true }
                else if byte != 13 && byte != 10 { throw KMError.device("raw REPL 结束标记异常，请重新连接。") }
            default: break
            }
        }
        result.completed = stage == 3
        return result
    }
}

public struct BoardEntry: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int
}

public struct UploadResult: Sendable {
    public let path: String
    public let bytes: Int
    public let backupPath: String?
}

public actor SerialREPL {
    private var port: SerialPort?
    private var decoder = RawREPLDecoder()
    public private(set) var running = false
    public private(set) var workingDirectory = ""
    public static let maximumFileBytes = 1024 * 1024
    public static var supportedBaudRates: [Int] { SerialPort.baudRates.keys.sorted() }

    public init() {}

    public func isConnected() -> Bool { port != nil }

    /// Like uPyCraft, entering the REPL interrupts the currently running board script.
    /// It deliberately does not send the raw-mode soft-reset command.
    public func connect(path: String, baud: Int = 115200) throws -> String {
        try Task.checkCancellation()
        guard port == nil else { throw KMError.invalid("请先断开当前串口。") }
        let opened = try SerialPort(path: path, baud: baud)
        port = opened
        do {
            try opened.write(Data([13, 3, 3]))
            Thread.sleep(forTimeInterval: 0.08)
            _ = try opened.available()
            try opened.write(Data([13, 1]))
            let banner = try opened.readUntil(Data("raw REPL; CTRL-B to exit\r\n>".utf8), timeout: 3)
            running = false
            let directory = try execute("import os\nprint(os.getcwd())")
            workingDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(decoding: banner, as: UTF8.self) + "MicroPython REPL 已连接；目录：\(workingDirectory)"
        } catch {
            opened.close(); port = nil; running = false
            throw error
        }
    }

    public func disconnect() throws {
        guard let port else { return }
        defer { port.close(); self.port = nil; running = false }
        if running { _ = try stop() }
        try port.write(Data([13, 2]))
    }

    public func begin(_ code: String) throws {
        try Task.checkCancellation()
        guard let port else { throw KMError.disconnected }
        guard !running else { throw KMError.invalid("脚本正在运行，请先停止。") }
        let data = try Self.sourceData(code)
        do {
            decoder = RawREPLDecoder()
            running = true
            for offset in stride(from: 0, to: data.count, by: 256) {
                try Task.checkCancellation()
                try port.write(Data(data[offset..<min(offset + 256, data.count)]))
                Thread.sleep(forTimeInterval: 0.01)
            }
            try port.write(Data([4]))
            let prefix = try port.readUntil(Data("OK".utf8), timeout: 3)
            guard prefix.isEmpty else { throw KMError.device("设备拒绝执行：\(String(decoding: prefix, as: UTF8.self))") }
        } catch {
            // The interpreter state is unknown after a framing/write error. Do not reuse it.
            port.close(); self.port = nil; running = false
            throw error
        }
    }

    /// The CLI can validate local source before opening (and interrupting) a device.
    public static func sourceData(_ code: String) throws -> Data {
        let data = Data(code.utf8)
        guard !data.isEmpty else { throw KMError.invalid("编辑区为空。") }
        guard data.count <= Self.maximumFileBytes else { throw KMError.invalid("单次脚本不得超过 1 MiB。") }
        // Control bytes would escape raw REPL and could change the device mode.
        guard !data.contains(where: { $0 < 32 && $0 != 9 && $0 != 10 && $0 != 13 }) else {
            throw KMError.invalid("脚本包含 REPL 控制字符。")
        }
        return data
    }

    public func pollOutput() throws -> REPLChunk {
        guard let port else { throw KMError.disconnected }
        guard running else { var result = REPLChunk(); result.completed = true; return result }
        do {
            let result = try decoder.feed(port.available())
            if result.completed { running = false }
            return result
        } catch { port.close(); self.port = nil; running = false; throw error }
    }

    public func beginInteractive(_ command: String) throws {
        try begin("exec(compile(\(Self.pythonString(command)), '<stdin>', 'single'), globals())")
    }

    public func beginFile(_ path: String) throws { try begin(Self.fileExecutionSource(path)) }

    private static func fileExecutionSource(_ path: String) -> String {
        """
        with open(\(pythonString(path)), 'r') as _km_script:
            _km_source = _km_script.read()
        if _km_source.startswith('\\ufeff'):
            _km_source = _km_source[1:]
        exec(compile(_km_source, \(pythonString(path)), 'exec'), globals())
        """
    }

    /// Explicit input for a script currently waiting in input()/stdin.
    public func sendInput(_ text: String) throws {
        guard let port else { throw KMError.disconnected }
        guard running else { throw KMError.invalid("没有正在等待输入的脚本。") }
        guard !text.utf8.contains(where: { $0 < 32 && $0 != 9 }) else { throw KMError.invalid("请发送单行文本；停止脚本使用停止按钮。") }
        try port.write(Data((text + "\r").utf8))
    }

    public func stop() throws -> REPLChunk {
        guard let port else { throw KMError.disconnected }
        guard running else { var result = REPLChunk(); result.completed = true; return result }
        try port.write(Data([3, 3]))
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        var result = REPLChunk()
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let chunk = try pollOutput()
            result.output.append(chunk.output); result.error.append(chunk.error)
            if chunk.completed { result.completed = true; return result }
            Thread.sleep(forTimeInterval: 0.01)
        }
        port.close(); self.port = nil; running = false
        throw KMError.timeout("Ctrl-C 后设备未回到 REPL；串口已关闭，请检查设备")
    }

    public func execute(_ code: String, timeout: TimeInterval = 8) throws -> String {
        guard timeout.isFinite, timeout > 0, timeout <= Double(UInt32.max) else {
            throw KMError.invalid("执行超时必须为正的有限秒数。")
        }
        try begin(code)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var output = Data(), errors = Data()
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try Task.checkCancellation()
            let chunk = try pollOutput()
            output.append(chunk.output); errors.append(chunk.error)
            if chunk.completed {
                if !errors.isEmpty { throw KMError.device(String(decoding: errors, as: UTF8.self)) }
                return String(decoding: output, as: UTF8.self)
            }
            if output.count + errors.count > 4 * 1024 * 1024 { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        // Keep the board's uncertain running state explicit; caller may Stop or reconnect.
        throw KMError.timeout("设备操作没有结束；可使用停止按钮中断")
    }

    public func list(_ directory: String) throws -> [BoardEntry] {
        let literal = Self.pythonString(directory)
        let response = try execute("""
        import os, json
        _km_dir = \(literal)
        _km_items = []
        for _km_name in os.listdir(_km_dir):
            _km_path = _km_dir.rstrip('/') + '/' + _km_name
            _km_stat = os.stat(_km_path)
            _km_items.append([_km_name, bool(_km_stat[0] & 0x4000), _km_stat[6]])
        print(json.dumps(_km_items))
        """)
        guard let values = try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [[Any]] else {
            throw KMError.device("设备目录响应不是有效的 JSON。")
        }
        return try values.map { row in
            guard row.count == 3, let name = row[0] as? String, let isDir = row[1] as? Bool,
                  let size = row[2] as? Int else { throw KMError.device("设备目录条目格式错误。") }
            return BoardEntry(name: name, path: Self.join(directory, name), isDirectory: isDir, size: size)
        }.sorted { $0.isDirectory == $1.isDirectory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.isDirectory }
    }

    public func readFile(_ path: String) throws -> Data {
        let literal = Self.pythonString(path)
        func fileSize() throws -> Int {
            let response = try execute("import os\nprint(os.stat(\(literal))[6])")
            guard let size = Int(response.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (0...Self.maximumFileBytes).contains(size) else {
                throw KMError.device("设备文件大小无效或超过 1 MiB。")
            }
            return size
        }
        let size = try fileSize()
        var result = Data()
        // Keep both device allocations and serial response time bounded, including at 9600 baud.
        for offset in stride(from: 0, to: size, by: 384) {
            let count = min(384, size - offset)
            let response = try execute("""
            import ubinascii
            with open(\(literal), 'rb') as _km_file:
                _km_file.seek(\(offset))
                print(ubinascii.hexlify(_km_file.read(\(count))).decode())
            """)
            guard let chunk = Data(hexadecimal: response.trimmingCharacters(in: .whitespacesAndNewlines)),
                  chunk.count == count else {
                throw KMError.device("文件响应长度或编码异常，文件可能在读取期间发生变化。")
            }
            result.append(chunk)
        }
        guard try fileSize() == size else { throw KMError.conflict("文件在读取期间大小发生变化，请重新读取。") }
        return result
    }

    /// expected == nil means create only; existing files must first be read to obtain a baseline.
    public func upload(_ data: Data, to path: String, expected: Data?) throws -> UploadResult {
        guard !path.isEmpty, !path.hasSuffix("/"), !path.contains("\0") else { throw KMError.invalid("文件路径无效。") }
        guard data.count <= Self.maximumFileBytes else { throw KMError.invalid("编辑器支持最大 1 MiB 的文件。") }
        try validateBaseline(path, expected: expected)
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let temporary = path + ".kmupload-" + suffix
        let backup = expected == nil ? nil : path + ".kmbak-" + suffix
        do {
            _ = try execute("with open(\(Self.pythonString(temporary)), 'wb') as _km_upload:\n    pass")
            for offset in stride(from: 0, to: data.count, by: 384) {
                let part = Data(data[offset..<min(data.count, offset + 384)])
                _ = try execute("import ubinascii\nwith open(\(Self.pythonString(temporary)), 'ab') as _km_upload:\n    _km_upload.write(ubinascii.unhexlify('\(part.hexadecimal)'))")
            }
            guard try readFile(temporary) == data else { throw KMError.device("上传读回校验失败，原文件未替换。") }
            try validateBaseline(path, expected: expected)
            if let backup {
                _ = try execute("import os\nos.rename(\(Self.pythonString(path)), \(Self.pythonString(backup)))")
            }
            _ = try execute("import os\nos.rename(\(Self.pythonString(temporary)), \(Self.pythonString(path)))")
            guard try readFile(path) == data else { throw KMError.device("替换后的读回校验失败。") }
            return UploadResult(path: path, bytes: data.count, backupPath: backup)
        } catch {
            throw KMError.device("\(error.localizedDescription)\n临时文件：\(temporary)\(backup.map { "\n原文件备份（若已进入替换阶段）：" + $0 } ?? "")\n未自动重试或清理，请核对设备文件。")
        }
    }

    private func validateBaseline(_ path: String, expected: Data?) throws {
        let exists = try fileExists(path)
        if let expected {
            guard exists, try readFile(path) == expected else {
                throw KMError.conflict("设备文件已变化或被删除，请重新读取后再上传：\(path)")
            }
        } else if exists { throw KMError.conflict("设备文件已存在，请先读取它再编辑上传：\(path)") }
    }

    public func fileExists(_ path: String) throws -> Bool {
        let response = try execute("""
        import os
        try:
            os.stat(\(Self.pythonString(path)))
            print('EXISTS')
        except OSError as _km_error:
            if _km_error.args[0] == 2:
                print('MISSING')
            else:
                raise
        """).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["EXISTS", "MISSING"].contains(response) else { throw KMError.device("设备文件状态响应异常。") }
        return response == "EXISTS"
    }

    public func createDirectory(_ path: String) throws {
        _ = try execute("import os\nos.mkdir(\(Self.pythonString(path)))")
    }

    public func rename(_ path: String, to destination: String) throws {
        guard try !fileExists(destination) else { throw KMError.conflict("目标名称已存在：\(destination)") }
        _ = try execute("import os\nos.rename(\(Self.pythonString(path)), \(Self.pythonString(destination)))")
    }

    public func remove(_ path: String, directory: Bool) throws {
        _ = try execute("import os\nos.\(directory ? "rmdir" : "remove")(\(Self.pythonString(path)))")
    }

    public func syntaxCheck(_ code: String, filename: String) throws -> String {
        try execute("compile(\(Self.pythonString(code)), \(Self.pythonString(filename)), 'exec')\nprint('MicroPython 语法检查通过')")
    }

    public func setStartupScript(_ path: String, expectedMain: Data?) throws -> UploadResult {
        let mainPath = Self.join(workingDirectory, "main.py")
        let canonicalPath = Self.normalized(path, relativeTo: workingDirectory)
        guard canonicalPath != Self.normalized(mainPath, relativeTo: workingDirectory) else {
            throw KMError.invalid("当前文件已是 main.py，无需再创建启动入口。")
        }
        guard try fileExists(path) else { throw KMError.invalid("先把脚本上传到设备，再设为启动脚本。") }
        let code = "# Generated by KMBox Mac. Original main.py is preserved in a .kmbak file.\n" + Self.fileExecutionSource(path) + "\n"
        return try upload(Data(code.utf8), to: mainPath, expected: expectedMain)
    }

    public static func pythonString(_ value: String) -> String {
        // JSON string escaping is also valid Python string escaping for these Unicode scalars.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try! encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    public static func join(_ directory: String, _ name: String) -> String {
        (directory == "/" ? "" : directory.trimmingSuffix("/")) + "/" + name
    }

    private static func normalized(_ path: String, relativeTo directory: String) -> String {
        let absolute = path.hasPrefix("/") ? path : join(directory, path)
        var parts: [Substring] = []
        for part in absolute.split(separator: "/") {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else if part != "." { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}
