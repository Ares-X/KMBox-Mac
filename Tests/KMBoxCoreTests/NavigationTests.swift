import XCTest
import SwiftUI
@testable import KMBoxApp

@MainActor
final class NavigationTests: XCTestCase {
    func testNavigationPreservesEditorSelectionUndoAndReceivesChangesWhileHidden() async throws {
        _ = NSApplication.shared
        let model = AppModel(temporarySession: true)
        model.page = .editor
        let view = NSHostingView(rootView: ContentView().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(findEditor(in: view))
        window.makeFirstResponder(editor)
        editor.insertText("# navigation draft\n", replacementRange: NSRange(location: 0, length: 0))
        await Task.yield()
        view.layoutSubtreeIfNeeded()
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertTrue(model.activeDocument?.text.hasPrefix("# navigation draft") == true)
        XCTAssertTrue(editor.undoManager?.canUndo == true)

        model.page = .control
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.firstResponder === editor)
        XCTAssertNil(findEditor(in: view), "A hidden editor must not remain in the visible view hierarchy")
        model.page = .editor
        view.layoutSubtreeIfNeeded()
        let returned = try XCTUnwrap(findEditor(in: view))
        XCTAssertEqual(returned.selectedRange(), NSRange(location: 5, length: 0))
        XCTAssertTrue(returned.undoManager?.canUndo == true)
        returned.undoManager?.undo()
        XCTAssertFalse(returned.string.hasPrefix("# navigation draft"))
        XCTAssertEqual(model.activeDocument?.text, returned.string)

        model.page = .activity
        view.layoutSubtreeIfNeeded()
        model.updateText("# external document update\n")
        await Task.yield()
        model.page = .editor
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(findEditor(in: view)?.string, "# external document update\n")
        _ = await model.shutdown()
    }

    private func findEditor(in view: NSView) -> PythonTextView? {
        if let editor = view as? PythonTextView { return editor }
        for child in view.subviews {
            if let editor = findEditor(in: child) { return editor }
        }
        return nil
    }
}
