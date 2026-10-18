import SwiftUI

/// The diff of the file selected in the Changes tab, shown as an inspector next to the panes, or the file itself
/// to edit. Clicking a line number starts a comment for the agent; the comments collect in a tray below.
struct DiffView: View {
    @Environment(SessionStore.self) private var store
    let selection: ChangeSelection
    @State private var lines: [DiffLine] = []
    /// The ids (indices) of the lines being commented on.
    @State private var commenting: ClosedRange<Int>?
    @State private var draft = ""
    @FocusState private var draftFocused: Bool
    @State private var editing = false
    /// Where the editor opens: the first change, or the hunk clicked.
    @State private var editLine: Int?
    @State private var searching = false
    @State private var query = ""
    /// Which of the matches is shown.
    @State private var match = 0
    @State private var findRequest = 0
    @FocusState private var queryFocused: Bool
    private let maxLines = 5000

    private var name: String { (selection.path as NSString).lastPathComponent }
    private var folder: String { (selection.path as NSString).deletingLastPathComponent }
    private var syntax: Syntax? { Syntax(path: selection.path) }
    /// The ids of the lines containing the search text.
    private var matches: [Int] {
        guard searching, !query.isEmpty else { return [] }
        return lines.filter { $0.kind != .hunk && $0.text.localizedCaseInsensitiveContains(query) }.map(\.id)
    }
    private var currentMatch: Int? { matches.isEmpty ? nil : matches[min(match, matches.count - 1)] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if editing, let root = store.selectedSession?.git?.root {
                FileEditorView(selection: selection, root: root, line: editLine, findRequest: findRequest)
                    .id(selection.path)
            } else {
                if searching { searchBar }
                diff
            }
            if let session = store.selectedSession, !session.reviewComments.isEmpty {
                Divider()
                tray(session)
            }
        }
        .task(id: selection) {
            lines = []
            commenting = nil
            while !Task.isCancelled {
                if let root = store.selectedSession?.git?.root {
                    let diff = await inBackground { Git.diff(of: selection, in: root) } ?? ""
                    let fresh = Git.parseDiff(diff)
                    if fresh != lines {
                        if lines.isEmpty { editLine = fresh.first { $0.kind != .hunk }?.new }
                        lines = fresh
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var diff: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.prefix(maxLines)) { line in
                        row(line)
                        if line.id == commenting?.upperBound { editor }
                    }
                }
            }
            .onChange(of: currentMatch) {
                if let currentMatch { proxy.scrollTo(currentMatch, anchor: .center) }
            }
        }
        .overlay {
            if lines.isEmpty { ContentUnavailableView("No Differences", systemImage: "checkmark.circle") }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in diff", text: $query)
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .onAppear { queryFocused = true }
                .onSubmit { step(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) }
                .onExitCommand { searching = false }
                .onChange(of: query) { match = 0 }
            if !query.isEmpty {
                Text(matches.isEmpty ? "No matches" : "\(min(match, matches.count - 1) + 1) of \(matches.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .help("Previous match (⇧↩)")
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .help("Next match (↩)")
            Button { searching = false } label: { Image(systemName: "xmark.circle.fill") }
                .foregroundStyle(.secondary)
                .help("Close the search (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func step(_ by: Int) {
        guard !matches.isEmpty else { return }
        match = (min(match, matches.count - 1) + by + matches.count) % matches.count
    }

    /// ⌘F: the search above the diff, or the editor's find bar.
    private func find() {
        if editing {
            findRequest += 1
        } else {
            searching = true
            queryFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(name).bold().lineLimit(1)
            Text(folder).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            Text(selection.staged ? "Staged" : "Working Tree").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Picker("Mode", selection: $editing) {
                Text("Diff").tag(false)
                Text("Edit").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show the diff, or edit the file in the working tree")
            Button(action: find) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f")
            .help("Find (⌘F)")
            Text("+\(lines.count { $0.kind == .added })").foregroundStyle(.green)
            Text("−\(lines.count { $0.kind == .removed })").foregroundStyle(.red)
            Button {
                store.selectedChange = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close the diff")
        }
        .monospacedDigit()
        .padding(10)
    }

    @ViewBuilder
    private func row(_ line: DiffLine) -> some View {
        if line.kind == .hunk {
            Text(line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.12))
                .contentShape(Rectangle())
                .onTapGesture {
                    editLine = lines.first { $0.id > line.id }?.new
                    editing = true
                }
                .help("Edit the file from here")
        } else {
            HStack(alignment: .top, spacing: 0) {
                HStack(spacing: 0) {
                    gutter(line.old)
                    gutter(line.new)
                }
                .contentShape(Rectangle())
                .onTapGesture { select(line.id) }
                .help("Comment on this line, ⇧-click for several")
                Text(marker(of: line.kind)).foregroundStyle(.secondary).frame(width: 18)
                Text(marked(line.text.isEmpty || line.kind == .note ? AttributedString(line.text + " ")
                            : syntax?.highlighted(line.text) ?? AttributedString(line.text),
                            text: line.text, current: line.id == currentMatch))
                    .italic(line.kind == .note)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12, design: .monospaced))
            .background(commenting?.contains(line.id) == true ? Color.accentColor.opacity(0.3) : background(of: line.kind))
        }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("Comment for the agent", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($draftFocused)
                .onSubmit(addComment)
                // Not a cancelAction shortcut: that would take Esc from the terminals too.
                .onExitCommand { commenting = nil }
            HStack {
                Button("Cancel") { commenting = nil }
                Button("Add Comment", action: addComment)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
        .onAppear { draftFocused = true }
    }

    private func tray(_ session: TerminalSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(session.reviewComments) { comment in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\((comment.path as NSString).lastPathComponent):\(comment.lines)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text(comment.text).lineLimit(2)
                    Spacer(minLength: 4)
                    Button {
                        session.reviewComments.removeAll { $0.id == comment.id }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove the comment")
                }
                .help(comment.path)
            }
            HStack {
                Button("Clear") { session.reviewComments = [] }
                Spacer()
                Button("Send to Agent") { session.sendReviewComments() }
                    .buttonStyle(.borderedProminent)
                    .help("Types the comments into \(session.displayName); press Return there to send them")
            }
        }
        .padding(10)
    }

    /// Starts a comment on one line, or with ⇧ extends it to the clicked line.
    private func select(_ id: Int) {
        if NSEvent.modifierFlags.contains(.shift), let range = commenting {
            commenting = min(range.lowerBound, id)...max(range.upperBound, id)
        } else {
            commenting = commenting == id...id ? nil : id...id
        }
    }

    private func addComment() {
        // The diff may have shrunk since the lines were picked.
        guard let range = commenting, range.upperBound < lines.count, let session = store.selectedSession,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.reviewComments.append(ReviewComment(path: selection.path, lines: lines[range], text: draft))
        draft = ""
        commenting = nil
    }

    /// `string` with the search text marked in it, more strongly on the current match.
    private func marked(_ string: AttributedString, text: String, current: Bool) -> AttributedString {
        guard searching, !query.isEmpty else { return string }
        var string = string
        var start = text.startIndex
        while let found = text.range(of: query, options: .caseInsensitive, range: start..<text.endIndex) {
            if let range = Range(NSRange(found, in: text), in: string) {
                string[range].backgroundColor = current ? .orange : .yellow
                string[range].foregroundColor = .black
            }
            start = found.upperBound
        }
        return string
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
    }

    private func marker(of kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private func background(of kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.2)
        case .removed: .red.opacity(0.2)
        default: .clear
        }
    }
}

/// A comment on lines of a diff, sent to the agent together with the others.
struct ReviewComment: Identifiable, Equatable {
    let id = UUID()
    var path: String
    /// "42" or "10-14" in the new file; the old file's numbers when only removed lines were picked.
    var lines: String
    var text: String

    init(path: String, lines: ArraySlice<DiffLine>, text: String) {
        let new = lines.compactMap(\.new)
        let numbers = new.isEmpty ? lines.compactMap(\.old) : new
        let first = numbers.first ?? 0, last = numbers.last ?? 0
        self.path = path
        self.lines = (first == last ? "\(first)" : "\(first)-\(last)") + (new.isEmpty ? " (removed)" : "")
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func message(_ comments: [ReviewComment]) -> String {
        "Review comments:\n" + comments.map {
            "- \($0.path):\($0.lines): " + $0.text.replacingOccurrences(of: "\n", with: "\n  ")
        }.joined(separator: "\n")
    }
}
