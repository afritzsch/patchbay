import SwiftUI

/// Edits the working-tree copy of a changed file, marking the lines that differ from git as you type. ⌘S saves;
/// leaving the file saves it too. While there are no unsaved edits it follows the file on disk, so an agent's
/// changes show up.
struct FileEditorView: View {
    @Environment(SessionStore.self) private var store
    let selection: ChangeSelection
    let root: String
    /// The line to show, 1-based.
    var line: Int?
    /// Opens the find bar each time it changes.
    var findRequest: Int
    @State private var text = ""
    /// What git has, which the changes are marked against.
    @State private var base: String?
    @State private var changes = LineChanges()
    /// The file's contents as last read or written; nil until read.
    @State private var saved: String?
    @State private var changedOnDisk = false
    @State private var error: String?
    private let maxSize = 2_000_000

    private var url: URL { URL(filePath: root).appending(path: selection.path) }
    private var edited: Bool { saved != nil && text != saved }

    var body: some View {
        VStack(spacing: 0) {
            if saved != nil {
                CodeEditor(text: $text, syntax: Syntax(path: selection.path), line: line, changes: changes,
                           findRequest: findRequest)
            } else if let error {
                ContentUnavailableView("Can't Edit", systemImage: "doc.questionmark", description: Text(error))
            } else {
                Spacer()
            }
            Divider()
            HStack {
                if let error, saved != nil {
                    Text(error).foregroundStyle(.red).lineLimit(2)
                } else if changedOnDisk {
                    Text("Changed on disk").foregroundStyle(.orange)
                    Button("Reload") { saved = nil }
                } else if edited {
                    Text("Edited").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut("s")
                    .disabled(!edited)
            }
            .font(.caption)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .task {
            while !Task.isCancelled {
                let (url, maxSize, selection, root) = (url, maxSize, selection, root)
                let (disk, base) = await inBackground {
                    (Result {
                        let data = try Data(contentsOf: url)
                        guard data.count <= maxSize else { throw EditorError("The file is larger than 2 MB.") }
                        guard let text = String(data: data, encoding: .utf8) else { throw EditorError("It isn't UTF-8 text.") }
                        return text
                    }, Git.base(of: selection, in: root))
                }
                if let base, base != self.base { self.base = base }
                switch disk {
                case .success(let contents) where contents != saved:
                    error = nil
                    if edited {
                        changedOnDisk = true
                    } else {
                        (text, saved, changedOnDisk) = (contents, contents, false)
                    }
                case .failure(let failure): error = failure.localizedDescription
                default: break
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: [text, base ?? ""]) {
            guard let base, (try? await Task.sleep(for: .milliseconds(150))) != nil else { return } // typing pauses
            let text = text
            changes = await inBackground { Git.lineChanges(from: base, to: text) }
        }
        .onDisappear { if edited { save() } }
    }

    private func save() {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            (saved, changedOnDisk, error) = (text, false, nil)
            store.selectedSession?.gitStale = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct EditorError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// A plain-text code view: monospaced, highlighted, with line numbers, find (⌘F) and auto-indent.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var syntax: Syntax?
    var line: Int?
    var changes: LineChanges
    var findRequest: Int

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1: the line-number ruler reads line positions from the layout manager.
        let textView = CodeTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = Self.font
        textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.textColor]
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.verticalRulerView = LineNumberRuler(textView: textView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight(textView)
        }
        textView.changes = changes
        if findRequest != context.coordinator.findRequest {
            context.coordinator.findRequest = findRequest
            textView.window?.makeFirstResponder(textView)
            let sender = NSMenuItem()
            sender.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(sender)
        }
        if let line, line != context.coordinator.shownLine {
            context.coordinator.shownLine = line
            show(line: line, in: textView)
        }
    }

    private func show(line: Int, in textView: NSTextView) {
        let string = textView.string as NSString
        var location = 0
        for _ in 1..<max(line, 1) where location < string.length {
            location = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
        }
        let range = NSRange(location: min(location, string.length), length: 0)
        textView.setSelectedRange(range)
        // After layout, or it scrolls to where the line was before the text was set.
        DispatchQueue.main.async { textView.scrollRangeToVisible(range) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var shownLine: Int?
        var findRequest: Int

        init(_ parent: CodeEditor) {
            self.parent = parent
            findRequest = parent.findRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlight(textView)
        }

        /// Return keeps the line's indentation.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let string = textView.string as NSString
            let line = string.substring(with: string.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0)))
            textView.insertText("\n" + line.prefix { $0 == " " || $0 == "\t" }, replacementRange: textView.selectedRange())
            return true
        }

        func highlight(_ textView: NSTextView) {
            // Big files stay plain: this runs on every keystroke.
            guard let storage = textView.textStorage, storage.length < 500_000 else { return }
            storage.beginEditing()
            storage.setAttributes([.font: CodeEditor.font, .foregroundColor: NSColor.textColor],
                                  range: NSRange(location: 0, length: storage.length))
            for (range, token) in parent.syntax?.tokens(in: storage.string) ?? [] {
                storage.addAttribute(.foregroundColor, value: token.color, range: range)
            }
            storage.endEditing()
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

/// Paints the changes behind the text: a green band on new or changed lines, a red line where lines were removed.
final class CodeTextView: NSTextView {
    var changes = LineChanges() {
        didSet {
            guard changes != oldValue else { return }
            needsDisplay = true
            enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        forEachVisibleLine { line, frame in
            if changes.added.contains(line) {
                NSColor.systemGreen.withAlphaComponent(0.15).setFill()
                frame.fill()
            }
            if changes.removed.contains(line) {
                NSColor.systemRed.setFill()
                NSRect(x: frame.minX, y: frame.minY - 1, width: frame.width, height: 2).fill()
            }
        }
    }

    /// Calls `body` with each visible line's 0-based number and its full-width frame, over all its wrapped rows.
    func forEachVisibleLine(_ body: (Int, NSRect) -> Void) {
        guard let layout = layoutManager, let container = textContainer else { return }
        let string = self.string as NSString
        let glyphs = layout.glyphRange(forBoundingRect: visibleRect, in: container)
        let end = NSMaxRange(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        var location = string.lineRange(for: NSRange(location: layout.characterIndexForGlyph(at: glyphs.location), length: 0)).location
        var number = 0
        string.enumerateSubstrings(in: NSRange(location: 0, length: location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            number += 1
        }
        repeat {
            let line = string.lineRange(for: NSRange(location: location, length: 0))
            var frame = layout.extraLineFragmentRect // the empty line after a final newline
            if line.length > 0 {
                let lineGlyphs = layout.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
                frame = layout.lineFragmentRect(forGlyphAt: lineGlyphs.location, effectiveRange: nil)
                    .union(layout.lineFragmentRect(forGlyphAt: NSMaxRange(lineGlyphs) - 1, effectiveRange: nil))
            }
            body(number, NSRect(x: 0, y: frame.minY + textContainerOrigin.y, width: bounds.width, height: frame.height))
            location = NSMaxRange(line)
            number += 1
        } while location < end
    }
}

/// Line numbers next to the text, with a bar on lines that differ from git.
private final class LineNumberRuler: NSRulerView {
    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        // Scrolling doesn't redraw a ruler by itself.
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: nil)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func redraw(_ notification: Notification) {
        if (notification.object as? NSView) == scrollView?.contentView { needsDisplay = true }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? CodeTextView, let layout = textView.layoutManager else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let rowHeight = layout.defaultLineHeight(for: CodeEditor.font)
        textView.forEachVisibleLine { line, frame in
            let y = convert(frame.origin, from: textView).y
            if textView.changes.added.contains(line) {
                NSColor.systemGreen.setFill()
                NSRect(x: ruleThickness - 3, y: y, width: 3, height: frame.height).fill()
            }
            if textView.changes.removed.contains(line) {
                NSColor.systemRed.setFill()
                NSRect(x: ruleThickness - 8, y: y - 2, width: 8, height: 4).fill()
            }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - 8 - size.width, y: y + (rowHeight - size.height) / 2),
                       withAttributes: attributes)
        }
    }
}
