import SwiftUI

/// All sessions at once, as a grid that fills the window. The gaps between columns and rows can be dragged
/// to resize them, and each card's screen preview scales with its card.
struct OverviewView: View {
    @Environment(SessionStore.self) private var store

    private let gutter: CGFloat = 12
    private let padding: CGFloat = 12
    private let minimumColumnWidth: CGFloat = 220
    private let minimumRowHeight: CGFloat = 170

    var body: some View {
        if store.sessions.isEmpty {
            EmptyStateView()
        } else {
            GeometryReader { geometry in
                grid(in: geometry.size)
            }
        }
    }

    private func grid(in size: CGSize) -> some View {
        let sessions = store.sessions
        let count = sessions.count
        let columns = store.overviewColumns > 0 ? min(store.overviewColumns, count) : autoColumns(count: count, in: size)
        let rows = (count + columns - 1) / columns
        let width = max(size.width - 2 * padding - gutter * CGFloat(columns - 1), 1)
        let height = max(size.height - 2 * padding - gutter * CGFloat(rows - 1), 1)
        let columnFractions = Self.fractions(store.overviewColumnFractions, count: columns)
        let rowFractions = Self.fractions(store.overviewRowFractions, count: rows)
        // Rows never get shorter than the minimum; with many sessions the grid scrolls instead.
        let rowHeights = rowFractions.map { max(CGFloat($0) * height, minimumRowHeight) }
        let fits = rowHeights.reduce(0, +) <= height + 1

        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            Group {
                                if index < count {
                                    OverviewCard(session: sessions[index], isFocused: store.selectedID == sessions[index].id)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: CGFloat(columnFractions[column]) * width, height: rowHeights[row])
                            if column < columns - 1 {
                                ResizeHandle(axis: .horizontal, thickness: gutter, fractions: columnFractions, index: column,
                                             length: width, minimum: minimumColumnWidth) {
                                    store.overviewColumnFractions = $0
                                } onDoubleClick: {
                                    store.overviewColumnFractions = []
                                }
                                .frame(height: rowHeights[row])
                            }
                        }
                    }
                    if row < rows - 1 {
                        ResizeHandle(axis: .vertical, thickness: gutter, fractions: rowFractions, index: row,
                                     length: height, minimum: minimumRowHeight) {
                            store.overviewRowFractions = $0
                        } onDoubleClick: {
                            store.overviewRowFractions = []
                        }
                    }
                }
            }
            .padding(padding)
        }
        .scrollDisabled(fits)
    }

    /// The column count whose cards come closest to a landscape window shape, without getting too small.
    private func autoColumns(count: Int, in size: CGSize) -> Int {
        var best = 1
        var bestScore = Double.infinity
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let w = (size.width - 2 * padding - gutter * CGFloat(columns - 1)) / CGFloat(columns)
            let h = (size.height - 2 * padding - gutter * CGFloat(rows - 1)) / CGFloat(rows)
            guard w >= minimumColumnWidth || columns == 1 else { break }
            var score = abs(log(Double(w / max(h, 1)) / 1.5))
            if h < minimumRowHeight { score += 10 } // would scroll
            if score < bestScore {
                bestScore = score
                best = columns
            }
        }
        return best
    }

    /// Saved fractions when they match the grid's current shape, otherwise equal shares.
    static func fractions(_ saved: [Double], count: Int) -> [Double] {
        saved.count == count ? saved : PaneLayout.even(count)
    }
}

/// A session's live terminal under a header. Click into the terminal to type; double-click the header (or use
/// its button) to open the session in the panes, drag the header to move it into a pane.
private struct OverviewCard: View {
    @Environment(SessionStore.self) private var store
    let session: TerminalSession
    let isFocused: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            TerminalContainer(session: session, isFocused: isFocused, splitsOnDrop: false)
                .clipShape(.rect(cornerRadius: 6))
                .frame(minHeight: 40, maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: session.needsAttention || isFocused ? 2 : 1)
                .allowsHitTesting(false)
        }
        .onHover { hovering = $0 }
    }

    private var borderColor: Color {
        if session.needsAttention { return .orange }
        if isFocused { return .accentColor }
        return Color.primary.opacity(hovering ? 0.25 : 0.08)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusIcon(session: session)
                Text(session.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(session.statusLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(session.statusColor)
                    .lineLimit(1)
                ElapsedText(since: session.statusSince)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { store.show(session.id) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help("Open in the panes")
            }
            HStack(spacing: 8) {
                Text(session.abbreviatedCwd)
                    .lineLimit(1)
                    .truncationMode(.head)
                GitBadge(session: session)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let detail = session.detailLine {
                Text(detail)
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ApprovalButtons(session: session)
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) { store.show(session.id) }
        .onTapGesture { store.selectedID = session.id }
        .onDrag { store.dragItem(for: session) }
        .contextMenu { SessionMenu(session: session) }
        .help("Double-click to open in the panes, drag onto a pane to move it there")
    }
}
