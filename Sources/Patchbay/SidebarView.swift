import SwiftUI

struct SidebarView: View {
    @Environment(SessionStore.self) private var store
    @State private var showAllExternal = false
    private let externalLimit = 3

    var body: some View {
        @Bindable var store = store
        List(selection: Binding(
            get: { store.mode == .panes ? store.selectedID : nil },
            set: { id in
                store.selectedID = id
                if id != nil { store.showOverview = false }
            }
        )) {
            Section {
                ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                    SessionRow(session: session, index: index, onScreen: store.layout?.contains(session.id) == true)
                        .tag(session.id)
                        .overlay {
                            RowDragSource(payload: .session(session.id), name: session.displayName,
                                          toolTip: index < 9 ? "⌘\(index + 1)" : nil) {
                                store.selectedID = session.id
                                store.showOverview = false
                            }
                        }
                        .contextMenu { contextMenu(for: session) }
                }
                .onInsert(of: [.terminalSession]) { index, _ in store.dropInSidebar(at: index) }
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    if !store.sessions.isEmpty {
                        Text(summary).monospacedDigit()
                    }
                }
            }
            if !store.externalSessions.isEmpty {
                Section {
                    ForEach(showAllExternal ? store.externalSessions : Array(store.externalSessions.prefix(externalLimit))) { external in
                        ExternalSessionRow(external: external)
                            .contextMenu {
                                Button("Move Into Patchbay") {
                                    store.bringIn(external, splitting: nil, zone: .right)
                                }
                                Button("Copy Path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(external.cwd, forType: .string)
                                }
                            }
                    }
                    if store.externalSessions.count > externalLimit {
                        Button(showAllExternal ? "Show Fewer" : "Show All (\(store.externalSessions.count))") {
                            showAllExternal.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                } header: {
                    Text("Claude in Other Terminals")
                }
            }
        }
        .listStyle(.sidebar)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadFileURLs(from: providers) { store.open(droppedURLs: $0) }
            return true
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                UsageBars()
            HStack {
                Button {
                    store.showNewSessionSheet = true
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            }
            .padding(10)
            .background(.bar)
        }
    }

    private var summary: String {
        let working = store.sessions.filter { $0.status == .agentWorking || { if case .running = $0.status { true } else { false } }($0) }.count
        var parts: [String] = []
        if working > 0 { parts.append("\(working) busy") }
        if store.attentionCount > 0 { parts.append("\(store.attentionCount) waiting") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func contextMenu(for session: TerminalSession) -> some View {
        Button("Rename…") { store.renamingID = session.id }
        Button("Show History") { store.showHistory(for: session) }
        if let focused = store.selectedID, focused != session.id, store.layout != nil {
            Button("Open in Split Right") { store.drop(session: session.id, on: focused, zone: .right) }
            Button("Open in Split Below") { store.drop(session: session.id, on: focused, zone: .bottom) }
        }
        if store.paneCount > 1, store.layout?.contains(session.id) == true {
            Button("Remove Pane") { store.closePane(session.id) }
        }
        Divider()
        Button("New Shell in This Folder") {
            store.newSession(directory: session.cwd, agent: nil)
        }
        Button("New \(store.menuAgent.name) Session in This Folder") {
            store.newSession(directory: session.cwd, agent: store.menuAgent)
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.cwd, forType: .string)
        }
        if let git = session.git {
            Button("Copy Branch Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(git.branch, forType: .string)
            }
        }
        Divider()
        Button("Close Session", role: .destructive) { store.confirmAndClose(session) }
    }
}

struct SessionRow: View {
    let session: TerminalSession
    let index: Int
    let onScreen: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusIcon(session: session)
                .font(.system(size: 13))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.displayName)
                        .fontWeight(session.needsAttention ? .semibold : .regular)
                        .lineLimit(1)
                    if let agent = session.agent {
                        Text(agent.name)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.purple.opacity(0.18), in: .rect(cornerRadius: 3))
                            .foregroundStyle(.purple)
                    }
                    Spacer(minLength: 4)
                    if session.needsAttention {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                    }
                    if onScreen {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Shown in a pane")
                    }
                    ElapsedText(since: session.statusSince)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(session.statusLabel)
                    .font(.caption)
                    .foregroundStyle(session.statusColor)
                if let detail = session.detailLine {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                HStack(spacing: 6) {
                    Text(session.abbreviatedCwd)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let git = session.git {
                        GitBadge(git: git).foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A Claude session running in another terminal app. Drag it onto a pane, or click the arrow, to move it here.
struct ExternalSessionRow: View {
    @Environment(SessionStore.self) private var store
    let external: ExternalSession

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: external.busy ? "sparkles" : "sparkle")
                    .foregroundStyle(external.busy ? .purple : .teal)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(external.displayName)
                        .lineLimit(1)
                    Text([external.hostApp ?? "Other terminal", external.busy ? "Working" : "Idle"].joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text((external.cwd as NSString).abbreviatingWithTildeInPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
            }
            // Not over the button, so that stays clickable.
            .overlay {
                RowDragSource(payload: .external(external), name: external.displayName,
                              toolTip: "Drag onto a pane to move this session here")
            }
            Button {
                store.bringIn(external, splitting: nil, zone: .right)
            } label: {
                Image(systemName: "arrow.down.forward.square")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("Move into Patchbay (quits it there, resumes the conversation here)")
        }
        .padding(.vertical, 3)
    }
}

/// Makes a sidebar row draggable without taking its clicks. With SwiftUI's `.itemProvider` or `.onDrag` the
/// list's drag tracking wins over clicks, so this AppKit view handles left clicks itself: a click calls `onClick`
/// on mouse-up, and a drag starts only after the mouse has moved a few points. Right and control clicks fall
/// through to the list for the context menu, and drops go to the list for reordering.
struct RowDragSource: NSViewRepresentable {
    @Environment(SessionStore.self) private var store
    let payload: DragPayload
    let name: String
    let toolTip: String?
    var onClick: (() -> Void)?

    func makeNSView(context: Context) -> RowDragSourceView { RowDragSourceView() }

    func updateNSView(_ view: RowDragSourceView, context: Context) {
        view.store = store
        view.payload = payload
        view.name = name
        view.toolTip = toolTip
        view.onClick = onClick
    }
}

final class RowDragSourceView: NSView, NSDraggingSource {
    weak var store: SessionStore?
    var payload: DragPayload?
    var name = ""
    var onClick: (() -> Void)?
    /// Where the left button went down, until a drag starts.
    private var mouseDownLocation: NSPoint?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let location = event.locationInWindow
        guard hypot(location.x - start.x, location.y - start.y) >= 5 else { return }
        mouseDownLocation = nil
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownLocation != nil { onClick?() }
        mouseDownLocation = nil
    }

    private func beginDrag(with event: NSEvent) {
        guard let store, let payload else { return }
        store.dragged = payload
        let item = NSPasteboardItem()
        item.setData(Data(name.utf8), forType: .terminalSession)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    /// The row as drawn, for the drag image.
    private func snapshot() -> NSImage? {
        guard let row = sequence(first: superview, next: { $0?.superview }).first(where: { $0 is NSTableRowView }) ?? superview
        else { return nil }
        let rect = convert(bounds, to: row)
        guard let rep = row.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        row.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : []
    }
}
