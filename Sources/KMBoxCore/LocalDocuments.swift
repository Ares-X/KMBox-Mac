import Foundation
import CoreFoundation

public enum TextEncoding: String, Sendable {
    case utf8 = "UTF-8"
    case gb18030 = "GB18030 / GBK"
    case utf16 = "UTF-16（带 BOM）"

    private var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf16: return .utf16
        case .gb18030:
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        }
    }

    public func decode(_ data: Data) throws -> String {
        if self == .utf16, !data.starts(with: [0xff, 0xfe]), !data.starts(with: [0xfe, 0xff]) {
            throw DocumentDecodingError(encoding: self)
        }
        guard var text = String(data: data, encoding: foundationEncoding) else { throw DocumentDecodingError(encoding: self) }
        // REPL compile() receives Unicode source, for which a file BOM is invalid.
        if text.first == "\u{feff}" { text.removeFirst() }
        return text
    }
}

public struct DocumentDecodingError: Error, LocalizedError {
    public let encoding: TextEncoding
    public var errorDescription: String? { "无法按 \(encoding.rawValue) 读取此文件，请检查文本编码。" }
}

public struct EditorDocument: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var name: String
    public var text: String
    public var savedText: String
    public var localURL: URL?
    public var localBaseline: Data?
    public var remotePath: String?
    public var remoteBaseline: Data?
    public var importedEncoding: String?
    public var dirty: Bool { text != savedText }
    public init(name: String = "untitled.py", text: String = "") {
        self.name = name; self.text = text; self.savedText = text
    }
    public static func open(_ url: URL, encoding: TextEncoding = .utf8) throws -> EditorDocument {
        let data = try Data(contentsOf: url)
        guard data.count <= SerialREPL.maximumFileBytes else { throw KMError.invalid("编辑器支持最大 1 MiB 的文本文件。") }
        let text = try decodeSource(data, name: url.lastPathComponent, encoding: encoding)
        var document = EditorDocument(name: url.lastPathComponent, text: text)
        document.localURL = url; document.localBaseline = data
        document.importedEncoding = encoding.rawValue
        return document
    }

    public static func decodeSource(_ data: Data, name: String, encoding: TextEncoding = .utf8) throws -> String {
        let text = try encoding.decode(data)
        return (name as NSString).pathExtension.lowercased() == "py" ? utf8CodingDeclaration(text) : text
    }

    /// Only the draft captured when a reload started may be replaced by its result.
    public mutating func reloadFromDevice(_ data: Data, replacingText expected: String) throws {
        guard text == expected else { throw KMError.conflict("读取期间编辑内容已变化，已保留新修改。需要重载时请再次读取。") }
        text = try Self.decodeSource(data, name: name)
        remoteBaseline = data
        if localURL == nil { savedText = text }
    }

    private static func utf8CodingDeclaration(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        let first = lines[0].trimmingCharacters(in: .whitespaces)
        let limit = min(lines.count, first.isEmpty || first.hasPrefix("#") ? 2 : 1)
        let pattern = try! NSRegularExpression(pattern: #"^[\t\f ]*#.*?coding[:=][\t ]*([-_.a-zA-Z0-9]+)"#)
        for index in 0..<limit {
            let line = lines[index] as NSString
            if let match = pattern.firstMatch(in: lines[index], range: NSRange(location: 0, length: line.length)) {
                lines[index] = line.replacingCharacters(in: match.range(at: 1), with: "utf-8")
                break
            }
        }
        return lines.joined(separator: "\n")
    }
    public mutating func save(to url: URL, replacing expected: Data?) throws {
        let data = Data(text.utf8)
        try LocalFiles.write(data, to: url, replacing: expected)
        localURL = url; localBaseline = data; savedText = text; name = url.lastPathComponent
        importedEncoding = TextEncoding.utf8.rawValue
    }
}

public enum LocalFiles {
    public static func write(_ data: Data, to url: URL, replacing expected: Data?) throws {
        let exists = FileManager.default.fileExists(atPath: url.path)
        if let expected {
            guard exists, try Data(contentsOf: url) == expected else { throw KMError.conflict("文件已被其他程序修改，请重新打开或另存为。") }
        } else if exists { throw KMError.conflict("目标文件已存在，需要明确选择替换。") }
        try data.write(to: url, options: .atomic)
    }
}

public struct LocalEntry: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let isDirectory: Bool
    public var name: String { url.lastPathComponent }
    public static func list(_ directory: URL) throws -> [LocalEntry] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return try urls.map { LocalEntry(url: $0, isDirectory: try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true) }
            .sorted { $0.isDirectory == $1.isDirectory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.isDirectory }
    }
}

public enum LocalPython {
    /// ast.parse checks syntax without executing the user's code; Python is optional for the native app.
    public static func check(_ source: String) throws -> String {
        let locations = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let executable = locations.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw KMError.invalid("未找到本机 Python 3。可连接 B 串口后使用盒内 MicroPython 语法检查。")
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-I", "-c", "import ast,sys; ast.parse(sys.stdin.read(), filename='<editor>'); print('本机 Python 语法检查通过；MicroPython 兼容性需由盒内检查确认。')"]
        process.standardInput = input; process.standardOutput = output; process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(source.utf8)); try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw KMError.device(text) }
        return text
    }
}
