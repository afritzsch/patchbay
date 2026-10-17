import SwiftUI

/// The diff of the file selected in the Changes tab, shown as an inspector next to the panes.
struct DiffView: View {
    @Environment(SessionStore.self) private var store
    let selection: ChangeSelection
    @State private var lines: [DiffLine] = []
    private let maxLines = 5000

    private var name: String { (selection.path as NSString).lastPathComponent }
    private var folder: String { (selection.path as NSString).deletingLastPathComponent }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.prefix(maxLines)) { row($0) }
                }
            }
            .overlay {
                if lines.isEmpty { ContentUnavailableView("No Differences", systemImage: "checkmark.circle") }
            }
        }
        .task(id: selection) {
            lines = []
            while !Task.isCancelled {
                if let root = store.selectedSession?.git?.root {
                    let diff = await Task.detached { Git.diff(of: selection, in: root) }.value ?? ""
                    let fresh = Git.parseDiff(diff)
                    if fresh != lines { lines = fresh }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(name).bold().lineLimit(1)
            Text(folder).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            Text(selection.staged ? "Staged" : "Working Tree").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
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
        } else {
            HStack(alignment: .top, spacing: 0) {
                gutter(line.old)
                gutter(line.new)
                Text(marker(of: line.kind)).foregroundStyle(.secondary).frame(width: 18)
                Text(line.text.isEmpty ? " " : line.text)
                    .italic(line.kind == .note)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12, design: .monospaced))
            .background(background(of: line.kind))
        }
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
