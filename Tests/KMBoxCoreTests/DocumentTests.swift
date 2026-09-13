import XCTest
@testable import KMBoxCore

final class DocumentTests: XCTestCase {
    func testASCIIScriptWithLegacyCookieDoesNotSaveNewChineseAsWrongEncoding() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".py")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("# coding: gbk\nprint('hello')\n".utf8).write(to: url)
        var document = try EditorDocument.open(url)
        document.text += "# 中文\n"
        try document.save(to: url, replacing: document.localBaseline)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# coding: utf-8"))
        XCTAssertTrue(text.contains("中文"))
    }

    func testDocumentSaveDetectsExternalModificationAndDoesNotLoseUserDraft() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("test.py")
        try Data("print('original')".utf8).write(to: file)
        var document = try EditorDocument.open(file)
        document.text = "print('draft')"
        try Data("print('external')".utf8).write(to: file)
        XCTAssertThrowsError(try document.save(to: file, replacing: document.localBaseline))
        XCTAssertEqual(try String(contentsOf: file), "print('external')")
        XCTAssertEqual(document.text, "print('draft')")
        XCTAssertTrue(document.dirty)
        let destination = folder.appendingPathComponent("saved.py")
        try document.save(to: destination, replacing: nil)
        XCTAssertEqual(try String(contentsOf: destination), "print('draft')")
        XCTAssertFalse(document.dirty)
        let restored = try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(restored.localBaseline, document.localBaseline)
        XCTAssertEqual(restored.id, document.id)
    }

    func testLocalSyntaxCheckDoesNotRunEditorCode() throws {
        XCTAssertTrue(try LocalPython.check("raise RuntimeError('not executed')").contains("通过"))
        XCTAssertThrowsError(try LocalPython.check("if :"))
    }

    func testLegacyChineseScriptOpensExplicitlyAndSavesAsUTF8WithoutChangingSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("legacy.py")
        // Independent GBK bytes: print('中文') followed by LF.
        let original = Data("#!/usr/bin/env python3\n# coding: gbk\n".utf8)
            + Data([0x70, 0x72, 0x69, 0x6e, 0x74, 0x28, 0x27, 0xd6, 0xd0, 0xce, 0xc4, 0x27, 0x29, 0x0a])
        try original.write(to: file)
        XCTAssertThrowsError(try EditorDocument.open(file)) { XCTAssertTrue($0 is DocumentDecodingError) }
        var document = try EditorDocument.open(file, encoding: .gb18030)
        let converted = "#!/usr/bin/env python3\n# coding: utf-8\nprint('中文')\n"
        XCTAssertEqual(document.text, converted)
        XCTAssertEqual(document.localBaseline, original)
        let saved = folder.appendingPathComponent("utf8.py")
        try document.save(to: saved, replacing: nil)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try Data(contentsOf: saved), Data(converted.utf8))
        XCTAssertEqual(document.importedEncoding, "UTF-8")
    }

    func testUTF8AndUTF16BOMAreRemovedBeforeREPLExecution() throws {
        let source = "print('你好')\n"
        let utf8File = Data([0xef, 0xbb, 0xbf]) + Data(source.utf8)
        XCTAssertEqual(try TextEncoding.utf8.decode(utf8File), source)
        let utf16File = try XCTUnwrap(source.data(using: .utf16))
        XCTAssertEqual(try TextEncoding.utf16.decode(utf16File), source)
        XCTAssertThrowsError(try TextEncoding.utf16.decode(Data([0x41, 0x00])))
    }
}
