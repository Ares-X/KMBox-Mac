import SwiftUI
import AppKit

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    var documentID: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let editor = PythonTextView(frame: NSRect(x: 0, y: 0, width: 556, height: 300))
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 556, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 12, height: 14)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        editor.backgroundColor = .textBackgroundColor
        editor.insertionPointColor = .labelColor
        editor.setAccessibilityLabel("Python 代码编辑器")
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.masksToBounds = true
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = LineNumberRuler(scrollView: scroll, editor: editor)
        scroll.rulersVisible = true
        editor.string = text
        editor.colorize()
        context.coordinator.documentID = documentID
        return scroll
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 600, height: proposal.height ?? 300)
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let editor = view.documentView as? PythonTextView else { return }
        context.coordinator.parent = self
        let switchedDocument = context.coordinator.documentID != documentID
        if switchedDocument || editor.string != text { editor.undoManager?.removeAllActions() }
        if switchedDocument {
            context.coordinator.documentID = documentID
            editor.setSelectedRange(NSRange(location: 0, length: 0))
        }
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            editor.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            editor.colorize()
            view.verticalRulerView?.needsDisplay = true
        }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if editor.font != font { editor.font = font; editor.colorize(); view.verticalRulerView?.needsDisplay = true }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var documentID: UUID?
        init(_ parent: CodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? PythonTextView else { return }
            parent.text = editor.string
            editor.colorize()
            editor.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

final class PythonTextView: NSTextView {
    private var coloring = false
    private static let tokens = try! NSRegularExpression(pattern: #"(?<string>'''[\s\S]*?'''|\"\"\"[\s\S]*?\"\"\"|'(?:\\.|[^'\\\n])*'|\"(?:\\.|[^\"\\\n])*\")|(?<comment>#[^\n]*)|(?<keyword>\b(?:and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield)\b)|(?<number>\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b)"#)

    func colorize() {
        guard !coloring, let storage = textStorage else { return }
        coloring = true
        defer { coloring = false }
        let selection = selectedRange()
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttributes([.foregroundColor: NSColor.labelColor,
                               .font: font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)], range: all)
        Self.tokens.enumerateMatches(in: string, range: all) { match, _, _ in
            guard let match else { return }
            let colors: [(String, NSColor)] = [("string", .systemGreen), ("comment", .secondaryLabelColor),
                                              ("keyword", .systemPurple), ("number", .systemOrange)]
            for (name, color) in colors {
                let range = match.range(withName: name)
                if range.location != NSNotFound { storage.addAttribute(.foregroundColor, value: color, range: range); break }
            }
        }
        storage.endEditing()
        setSelectedRange(selection)
        typingAttributes = [.font: font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                            .foregroundColor: NSColor.labelColor]
    }

    override func insertNewline(_ sender: Any?) {
        let content = string as NSString
        let selection = selectedRange()
        let line = content.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefix = content.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
        let extra = prefix.trimmingCharacters(in: .whitespaces).hasSuffix(":") ? "    " : ""
        insertText("\n" + indent + extra, replacementRange: selection)
    }
    override func insertTab(_ sender: Any?) {
        if selectedRange().length > 0 { indentSelection(nil) }
        else { insertText("    ", replacementRange: selectedRange()) }
    }
    override func insertBacktab(_ sender: Any?) { unindentSelection(nil) }

    @objc func indentSelection(_ sender: Any?) { transformLines { "    " + $0 } }
    @objc func unindentSelection(_ sender: Any?) {
        transformLines { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.dropFirst(min(4, line.prefix { $0 == " " }.count)))
        }
    }
    @objc func toggleComment(_ sender: Any?) {
        let content = string as NSString
        let range = selectedLineRange(content)
        let lines = content.substring(with: range).components(separatedBy: "\n")
        let nonempty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let remove = !nonempty.isEmpty && nonempty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        transformLines { line in
            guard !line.isEmpty else { return line }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            var rest = String(line.dropFirst(indent.count))
            if remove, rest.hasPrefix("#") { rest.removeFirst(); if rest.hasPrefix(" ") { rest.removeFirst() } }
            else if !remove { rest = "# " + rest }
            return indent + rest
        }
    }
    private func selectedLineRange(_ content: NSString) -> NSRange {
        var selection = selectedRange()
        if selection.length > 0, selection.location + selection.length <= content.length,
           content.character(at: selection.location + selection.length - 1) == 10 { selection.length -= 1 }
        return content.lineRange(for: selection)
    }
    private func transformLines(_ transform: (String) -> String) {
        let content = string as NSString, range = selectedLineRange(string as NSString)
        var body = content.substring(with: range)
        let trailing = body.hasSuffix("\n")
        if trailing { body.removeLast() }
        let replacement = body.components(separatedBy: "\n").map(transform).joined(separator: "\n") + (trailing ? "\n" : "")
        insertText(replacement, replacementRange: range)
        setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
    }
}

final class LineNumberRuler: NSRulerView {
    weak var editor: NSTextView?
    init(scrollView: NSScrollView, editor: NSTextView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 44
        clientView = editor
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        // The dirty rect can extend beyond a ruler's bounds on modern macOS.
        // Clip explicitly so the gutter cannot paint over neighboring editor controls.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        let text = editor.string as NSString
        let visible = editor.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var position = text.lineRange(for: NSRange(location: min(characters.location, text.length), length: 0)).location
        var lineNumber = text.substring(to: position).filter { $0 == "\n" }.count + 1
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                       .foregroundColor: NSColor.tertiaryLabelColor]
        while position < text.length && position <= characters.location + characters.length {
            let glyph = layout.glyphIndexForCharacter(at: position)
            let frame = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let number = String(lineNumber) as NSString
            number.draw(at: NSPoint(x: ruleThickness - 9 - number.size(withAttributes: attributes).width,
                                    y: frame.minY + editor.textContainerInset.height - visible.minY + 1), withAttributes: attributes)
            let next = NSMaxRange(text.lineRange(for: NSRange(location: position, length: 0)))
            if next <= position { break }
            position = next; lineNumber += 1
        }
        if text.length == 0 {
            ("1" as NSString).draw(at: NSPoint(x: ruleThickness - 16, y: editor.textContainerInset.height), withAttributes: attributes)
        }
    }
}
