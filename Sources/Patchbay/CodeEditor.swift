import SwiftUI

/// Edits the working-tree copy of a changed file, marking the lines that differ from git as you type. ⌘S saves;
/// leaving the file saves it too. While there are no unsaved edits it follows the file on disk, so an agent's
/// changes show up. With a language server for the file: errors and warnings, completions (Esc, or while
/// typing), what is under the cursor in the status bar, and ⌘-click to go to a definition.
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
    @State private var server: LanguageServer?
    @State private var jump: CodeEditor.Jump?
    /// The cursor's UTF-16 offset.
    @State private var cursor = 0
    /// What the server says about the symbol at the cursor, or where its definition is.
    @State private var note: String?
    private let maxSize = 2_000_000

    private var url: URL { URL(filePath: root).appending(path: selection.path) }
    private var edited: Bool { saved != nil && text != saved }
    private var diagnostics: [LSP.Diagnostic] { server?.diagnostics[url.path] ?? [] }
    private var errors: [LSP.Diagnostic] { diagnostics.filter(\.isError) }

    var body: some View {
        VStack(spacing: 0) {
            if saved != nil {
                CodeEditor(text: $text, syntax: Syntax(path: selection.path), jump: jump, changes: changes,
                           diagnostics: diagnostics, findRequest: findRequest,
                           onCursor: { cursor = $0 },
                           complete: server == nil ? nil : { await completions(in: $0, at: $1) },
                           onCommandClick: server == nil ? nil : { goToDefinition(at: $0) })
            } else if let error {
                ContentUnavailableView("Can't Edit", systemImage: "doc.questionmark", description: Text(error))
            } else {
                Spacer()
            }
            Divider()
            if let info = cursorInfo {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let severity = info.severity { severityIcon(severity) }
                    Text(info.text).lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                Divider()
            }
            statusBar
        }
        .task {
            server = store.languageServers.server(for: selection.path, root: root)
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
            guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return } // typing pauses
            if saved != nil { server?.sync(url, text: text) }
            guard let base else { return }
            let text = text
            changes = await inBackground { Git.lineChanges(from: base, to: text) }
        }
        .task(id: cursor) {
            note = nil
            guard let server, saved != nil, (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            server.sync(url, text: text) // positions past the server's copy of a line crash sourcekit-lsp
            note = await server.hover(url, at: LSP.position(at: cursor, in: text as NSString))?.summary
        }
        .onChange(of: line, initial: true) {
            if let line { jump = CodeEditor.Jump(position: LSP.Position(line: line - 1, character: 0)) }
        }
        .onDisappear {
            if edited { save() }
            if let server {
                server.close(url)
                store.languageServers.release(server)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let error, saved != nil {
                Text(error).foregroundStyle(.red).lineLimit(2)
            } else if changedOnDisk {
                Text("Changed on disk").foregroundStyle(.orange)
                Button("Reload") { saved = nil }
            } else if edited {
                Text("Edited").foregroundStyle(.secondary)
            }
            if let server { serverStatus(server) }
            Spacer(minLength: 0)
            let warnings = diagnostics.count - errors.count
            if !diagnostics.isEmpty {
                Button(action: nextDiagnostic) {
                    HStack(spacing: 6) {
                        if !errors.isEmpty { severityIcon(1); Text("\(errors.count)") }
                        if warnings > 0 { severityIcon(2); Text("\(warnings)") }
                    }
                    .monospacedDigit()
                }
                .buttonStyle(.borderless)
                .help("Go to the next problem")
            }
            if !errors.isEmpty, let session = store.selectedSession {
                Button("Send Errors") { sendErrors(to: session) }
                    .help("Adds the errors to the review comments, to send them to \(session.displayName)")
            }
            Button("Save", action: save)
                .keyboardShortcut("s")
                .disabled(!edited)
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func serverStatus(_ server: LanguageServer) -> some View {
        switch server.state {
        case .starting:
            Text("Starting \(server.config.name)…").foregroundStyle(.secondary)
        case .ready:
            if let activity = server.activity.values.sorted().first {
                Text("\(server.config.name): \(activity)…").foregroundStyle(.secondary).lineLimit(1)
            }
        case .failed(let message):
            Text(message).foregroundStyle(.secondary).lineLimit(1)
            Button("Restart") {
                self.server = store.languageServers.server(for: selection.path, root: root)
                self.server?.sync(url, text: text)
            }
        case .stopped:
            EmptyView()
        }
    }

    private func severityIcon(_ severity: Int) -> some View {
        Image(systemName: severity == 1 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(severity == 1 ? .red : .yellow)
    }

    /// The problem on the cursor's line, else what the server said about the symbol there.
    private var cursorInfo: (text: String, severity: Int?)? {
        let line = LSP.position(at: cursor, in: text as NSString).line
        if let problem = diagnostics.first(where: { $0.range.start.line <= line && line <= $0.range.end.line }) {
            return (problem.message, problem.severity ?? 1)
        }
        return note.map { ($0, nil) }
    }

    private func nextDiagnostic() {
        let line = LSP.position(at: cursor, in: text as NSString).line
        let sorted = diagnostics.sorted { ($0.range.start.line, $0.range.start.character) < ($1.range.start.line, $1.range.start.character) }
        if let next = sorted.first(where: { $0.range.start.line > line }) ?? sorted.first {
            jump = CodeEditor.Jump(position: next.range.start)
        }
    }

    private func sendErrors(to session: TerminalSession) {
        for error in errors {
            let comment = ReviewComment(path: selection.path, line: error.range.start.line + 1, text: error.message)
            if !session.reviewComments.contains(where: { $0.path == comment.path && $0.lines == comment.lines && $0.text == comment.text }) {
                session.reviewComments.append(comment)
            }
        }
    }

    private func completions(in text: String, at location: Int) async -> [String] {
        guard let server else { return [] }
        server.sync(url, text: text)
        let items = await server.completions(url, at: LSP.position(at: location, in: text as NSString))
        var seen = Set<String>()
        return items.sorted { ($0.sortText ?? $0.label) < ($1.sortText ?? $1.label) }
            .map(\.text).filter { seen.insert($0).inserted }.prefix(100).map { $0 }
    }

    private func goToDefinition(at location: Int) {
        guard let server else { return }
        server.sync(url, text: text)
        let position = LSP.position(at: location, in: text as NSString)
        Task {
            guard let target = await server.definition(url, at: position), let file = URL(string: target.uri) else {
                note = "No definition found"
                return
            }
            if file.path == url.path {
                jump = CodeEditor.Jump(position: target.range.start)
            } else if file.path.hasPrefix(root + "/") {
                store.openInEditor(path: String(file.path.dropFirst(root.count + 1)), line: target.range.start.line + 1)
            } else {
                note = "Defined in \(file.lastPathComponent), outside the repository"
            }
        }
    }

    private func save() {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            (saved, changedOnDisk, error) = (text, false, nil)
            server?.sync(url, text: text)
            server?.saved(url)
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
    /// Moves the cursor to a position; each one made moves it, also to the same place again.
    struct Jump: Equatable {
        var position: LSP.Position
        private let id = UUID()
        init(position: LSP.Position) { self.position = position }
    }

    @Binding var text: String
    var syntax: Syntax?
    var jump: Jump?
    var changes: LineChanges
    var diagnostics: [LSP.Diagnostic] = []
    var findRequest: Int
    var onCursor: ((Int) -> Void)?
    /// The completions for a text at a location.
    var complete: ((String, Int) async -> [String])?
    var onCommandClick: ((Int) -> Void)?

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
            textView.markDiagnostics()
        }
        textView.changes = changes
        textView.diagnostics = diagnostics
        textView.completionSource = complete
        textView.onCommandClick = onCommandClick
        if findRequest != context.coordinator.findRequest {
            context.coordinator.findRequest = findRequest
            textView.window?.makeFirstResponder(textView)
            let sender = NSMenuItem()
            sender.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(sender)
        }
        if let jump, jump != context.coordinator.shownJump {
            context.coordinator.shownJump = jump
            let range = NSRange(location: LSP.location(of: jump.position, in: textView.string as NSString), length: 0)
            textView.setSelectedRange(range)
            textView.window?.makeFirstResponder(textView)
            textView.reveal(range)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var shownJump: Jump?
        var findRequest: Int

        init(_ parent: CodeEditor) {
            self.parent = parent
            findRequest = parent.findRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlight(textView)
            (textView as? CodeTextView)?.typed()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let location = textView.selectedRange().location
            // Not during SwiftUI's update, which sets the selection when it jumps.
            DispatchQueue.main.async { self.parent.onCursor?(location) }
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
/// Underlines problems, asks for completions, and reports ⌘-clicks.
final class CodeTextView: NSTextView {
    var diagnostics: [LSP.Diagnostic] = [] {
        didSet { if diagnostics != oldValue { markDiagnostics() } }
    }
    /// Lines with problems, and whether one of them is an error, for the ruler.
    private(set) var problemLines: [Int: Bool] = [:]
    var completionSource: ((String, Int) async -> [String])?
    var onCommandClick: ((Int) -> Void)?
    private var completionItems: [String] = []
    private var completionTask: Task<Void, Never>?
    private var typingTask: Task<Void, Never>?
    private var isCompleting = false
    private var pendingReveal: NSRange?

    var changes = LineChanges() {
        didSet {
            guard changes != oldValue else { return }
            needsDisplay = true
            enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }

    /// Dotted underlines on the problems: temporary attributes, which leave the text and the undo stack alone.
    func markDiagnostics() {
        guard let layout = layoutManager else { return }
        let text = string as NSString
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: text.length))
        problemLines = [:]
        for problem in diagnostics.sorted(by: { !$0.isError && $1.isError }) { // errors drawn last, over warnings
            let start = LSP.location(of: problem.range.start, in: text)
            var range = NSRange(location: start, length: max(LSP.location(of: problem.range.end, in: text) - start, 0))
            if range.length == 0 { // a point: underline the character there, or the one before at a line's end
                let lineEnd = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
                if start < lineEnd, start < text.length, text.character(at: start) != 10 { range.length = 1 }
                else if start > 0 { range = NSRange(location: start - 1, length: 1) }
            }
            layout.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                           .underlineColor: problem.isError ? NSColor.systemRed : NSColor.systemYellow],
                                          forCharacterRange: range)
            for line in problem.range.start.line...max(problem.range.end.line, problem.range.start.line) {
                problemLines[line] = problemLines[line] == true || problem.isError
            }
        }
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Scrolls to a range once the view has its size: a new editor gets one only when SwiftUI lays it out.
    func reveal(_ range: NSRange) {
        pendingReveal = range
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let range = pendingReveal, let clip = enclosingScrollView?.contentView, clip.bounds.height > 0 else { return }
        pendingReveal = nil
        DispatchQueue.main.async { self.scrollRangeToVisible(range) } // after this layout pass
    }

    // MARK: Completion

    /// Esc, or a pause while typing: asks for the completions first, then shows AppKit's list of them.
    override func complete(_ sender: Any?) {
        guard let completionSource else { return super.complete(sender) }
        let location = selectedRange().location, text = string
        completionTask?.cancel()
        completionTask = Task {
            let items = await completionSource(text, location)
            guard !Task.isCancelled, !items.isEmpty, string == text, selectedRange() == NSRange(location: location, length: 0)
            else { return }
            completionItems = items
            isCompleting = true
            super.complete(sender)
        }
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        completionSource == nil ? super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index) : completionItems
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        if flag { isCompleting = false }
    }

    /// The identifier before the cursor, which a completion replaces.
    override var rangeForUserCompletion: NSRange {
        let text = string as NSString
        let end = selectedRange().location
        var start = end
        while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)),
              scalar == "_" || CharacterSet.alphanumerics.contains(scalar) {
            start -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// Shows completions without Esc: right after a ".", or when a word of three letters or more rests for a
    /// moment. Not in comments and strings.
    func typed() {
        typingTask?.cancel()
        let location = selectedRange().location
        guard completionSource != nil, !isCompleting, selectedRange().length == 0, location > 0 else { return }
        let afterDot = (string as NSString).character(at: location - 1) == 46
        guard afterDot || rangeForUserCompletion.length >= 3 else { return }
        let color = textStorage?.attribute(.foregroundColor, at: location - 1, effectiveRange: nil) as? NSColor
        guard color != Syntax.Token.comment.color, color != Syntax.Token.string.color else { return }
        typingTask = Task {
            guard (try? await Task.sleep(for: .milliseconds(afterDot ? 50 : 400))) != nil,
                  selectedRange() == NSRange(location: location, length: 0) else { return }
            complete(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let onCommandClick else { return super.mouseDown(with: event) }
        let location = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        setSelectedRange(NSRange(location: location, length: 0))
        onCommandClick(location)
    }

    // MARK: Drawing

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

/// Line numbers next to the text, with a bar on lines that differ from git and a dot on lines with problems.
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
            if let isError = textView.problemLines[line] {
                (isError ? NSColor.systemRed : NSColor.systemYellow).setFill()
                NSBezierPath(ovalIn: NSRect(x: 4, y: y + (rowHeight - 6) / 2, width: 6, height: 6)).fill()
            }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - 8 - size.width, y: y + (rowHeight - size.height) / 2),
                       withAttributes: attributes)
        }
    }
}
