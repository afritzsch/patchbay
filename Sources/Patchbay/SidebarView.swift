import SwiftUI

struct SidebarView: View {
    @Environment(SessionStore.self) private var store
    @State private var showAllExternal = false
    /// Where a ⇧-click range starts: the row last clicked.
    @State private var anchorID: UUID?
    private let externalLimit = 3

    var body: some View {
        @Bindable var store = store
        Group {
            switch store.sidebarTab {
            case .sessions: sessionList
            case .automations: AutomationsView()
            case .changes: ChangesView()
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("", selection: $store.sidebarTab) {
                Text("Sessions").tag(SidebarTab.sessions)
                Text("Automations").tag(SidebarTab.automations)
                Text(changeCount > 0 ? "Changes \(changeCount)" : "Changes").tag(SidebarTab.changes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var changeCount: Int { store.selectedSession?.git?.changed ?? 0 }

    @ViewBuilder
    private var sessionList: some View {
        @Bindable var store = store
        List(selection: Binding(
            get: {
                if !store.multiSelection.isEmpty { return store.multiSelection }
                return store.mode == .panes ? Set([store.selectedID].compactMap { $0 }) : []
            },
            set: { ids in
                if ids.count > 1 { store.multiSelection = ids } else if let id = ids.first { store.show(id) } else { store.selectedID = nil }
            }
        )) {
            ForEach($store.groups) { $group in
                Section(isExpanded: $group.isExpanded) {
                    rows(in: group.id)
                } header: {
                    header(group.name, group: group.id)
                        .contextMenu { GroupMenu(group: group) }
                }
            }
            if store.groups.isEmpty || store.sessions.contains(where: { $0.groupID == nil }) {
                Section {
                    rows(in: nil)
                } header: {
                    header(store.groups.isEmpty ? "Sessions" : "Ungrouped", group: nil)
                }
            }
            if !store.externalSessions.isEmpty {
                Section {
                    ForEach(showAllExternal ? store.externalSessions : Array(store.externalSessions.prefix(externalLimit))) { external in
                        ExternalSessionRow(external: external)
                            .contextMenu {
                                Button("Move Into Patchbay") {
                                    store.confirmAndBringIn(external, splitting: nil, zone: .right)
                                }
                                Button("Copy Path") { copyToPasteboard(external.cwd) }
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
        .dropDestination(for: URL.self) { urls, _ in
            store.open(droppedURLs: urls)
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

    private func rows(in group: UUID?) -> some View {
        ForEach(Array(store.sessions.enumerated()).filter { $0.element.groupID == group }, id: \.element.id) { index, session in
            // The buttons are outside the drag source, which takes the row's clicks.
            VStack(alignment: .leading, spacing: 4) {
                SessionRow(session: session, index: index, onScreen: store.layout?.contains(session.id) == true)
                    .overlay {
                        RowDragSource(payload: .session(session.id), name: session.displayName,
                                      toolTip: index < 9 ? "⌘\(index + 1)" : nil) { click(session.id, $0) }
                    }
                ApprovalButtons(session: session)
                    .padding(.leading, 26)
                    .padding(.bottom, 3)
            }
                .tag(session.id)
                .contextMenu {
                    if store.multiSelection.contains(session.id) { SelectionMenu() } else { SessionMenu(session: session) }
                }
        }
        .onInsert(of: [.terminalSession]) { index, _ in store.dropInSidebar(at: index, group: group) }
    }

    private func header(_ title: String, group: UUID?) -> some View {
        let sessions = store.sessions.filter { $0.groupID == group }
        let working = sessions.filter { $0.isBusy && $0.status != .agentNeedsInput }.count
        let waiting = sessions.filter(\.needsAttention).count
        var parts: [String] = []
        if working > 0 { parts.append("\(working) busy") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return HStack {
            Text(title)
            Spacer()
            Text(parts.joined(separator: " · ")).monospacedDigit()
        }
        // Sidebar headers run to the column edge; line up with the rows' trailing column instead.
        .padding(.trailing, 14)
    }

    /// A click focuses the session; ⌘-click adds it to the selection or takes it out, ⇧-click adds the rows
    /// from the one clicked before.
    private func click(_ id: UUID, _ modifiers: NSEvent.ModifierFlags) {
        defer { anchorID = id }
        guard modifiers.contains(.command) || modifiers.contains(.shift) else { return store.show(id) }
        var picked = store.multiSelection.isEmpty ? Set([store.selectedID].compactMap { $0 }) : store.multiSelection
        let ids = store.sessions.map(\.id)
        if modifiers.contains(.shift), let from = ids.firstIndex(of: anchorID ?? store.selectedID ?? id),
           let to = ids.firstIndex(of: id) {
            picked.formUnion(ids[min(from, to)...max(from, to)])
        } else if picked.remove(id) == nil {
            picked.insert(id)
        }
        if picked.count > 1 { store.multiSelection = picked } else if let only = picked.first { store.show(only) }
    }
}

/// The context menu of the sessions selected with ⌘- or ⇧-click.
struct SelectionMenu: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        let sessions = store.sessions.filter { store.multiSelection.contains($0.id) }
        Button("Open \(sessions.count) as Panes") { store.showAsPanes(sessions.map(\.id)) }
        MoveToGroupMenu(ids: sessions.map(\.id))
        Divider()
        Button("Close \(sessions.count) Sessions", role: .destructive) { store.confirmAndClose(sessions) }
    }
}

/// The context menu of a group's header.
struct GroupMenu: View {
    @Environment(SessionStore.self) private var store
    let group: SessionGroup

    var body: some View {
        let sessions = store.sessions.filter { $0.groupID == group.id }
        let pinned = group.id == SessionGroup.pinnedID
        Button("Open as Panes") { store.showAsPanes(sessions.map(\.id)) }
        if !pinned { Button("Rename Group…") { store.renamingID = group.id } }
        Button(pinned ? "Unpin All" : "Ungroup") { store.move(sessions.map(\.id), to: nil) }
        Divider()
        Button("Close \(sessions.count) Sessions", role: .destructive) { store.confirmAndClose(sessions) }
    }
}

struct MoveToGroupMenu: View {
    @Environment(SessionStore.self) private var store
    let ids: [UUID]

    var body: some View {
        Menu("Move to Group") {
            Button("New Group…") { store.newGroup(with: ids) }
            if !store.groups.isEmpty { Divider() }
            ForEach(store.groups) { group in
                Button(group.name) { store.move(ids, to: group.id) }
            }
            if store.sessions.contains(where: { ids.contains($0.id) && $0.groupID != nil }) {
                Divider()
                Button("Remove from Group") { store.move(ids, to: nil) }
            }
        }
    }
}

/// The context menu of a session, wherever it is shown.
struct SessionMenu: View {
    @Environment(SessionStore.self) private var store
    let session: TerminalSession

    var body: some View {
        if store.mode != .panes || store.layout?.contains(session.id) != true {
            Button("Open in Panes") { store.show(session.id) }
        }
        Button("Rename…") { store.renamingID = session.id }
        Button(session.groupID == SessionGroup.pinnedID ? "Unpin" : "Pin") { store.togglePin(session) }
        Button("Show History") { store.showHistory(for: session) }
        MoveToGroupMenu(ids: [session.id])
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
        if session.git != nil {
            Button("New Worktree Session…") { store.newWorktreeSession(in: session.cwd) }
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
        }
        Button("Copy Path") { copyToPasteboard(session.cwd) }
        if let git = session.git {
            Button("Copy Branch Name") { copyToPasteboard(git.branch) }
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
            VStack(spacing: 2) {
                StatusIcon(session: session)
                    .font(.system(size: 13))
                    .padding(.top, 1)
                // The ⌘1–9 shortcut.
                if index < 9 {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(session.rowTitle)
                        .fontWeight(session.needsAttention ? .semibold : .regular)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if session.needsAttention {
                        Circle().fill(.orange).frame(width: 7, height: 7)
                    }
                    if onScreen {
                        Image(systemName: "rectangle.split.2x1.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .help("Shown in a pane; dragging it moves it out of that pane")
                    }
                    ElapsedText(since: session.statusSince)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(session.statusLabel)
                    .font(.caption)
                    .foregroundStyle(session.statusColor)
                if let detail = session.detailLine, detail != session.rowTitle {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                HStack(spacing: 6) {
                    if let agent = session.agent { AgentBadge(name: agent.name) }
                    Text(session.abbreviatedCwd)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    GitBadge(session: session).foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
        }
        .padding(.vertical, 3)
    }
}

/// The agent's name in a purple tag, in the sidebar's rows.
struct AgentBadge: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.purple.opacity(0.18), in: .rect(cornerRadius: 3))
            .foregroundStyle(.purple)
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
                store.confirmAndBringIn(external, splitting: nil, zone: .right)
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
    var onClick: ((NSEvent.ModifierFlags) -> Void)?

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
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    /// Where the left button went down, until a drag starts.
    private var mouseDownLocation: NSPoint?
    /// The pane the dragged session is shown in, marked while the drag lasts.
    private weak var leavingPane: TerminalHostView?

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
        if mouseDownLocation != nil { onClick?(event.modifierFlags) }
        mouseDownLocation = nil
    }

    private func beginDrag(with event: NSEvent) {
        guard let store, let payload else { return }
        store.dragged = payload
        if case .session(let id) = payload, store.mode == .panes, store.layout?.contains(id) == true,
           let pane = store.session(id)?.terminal.superview as? TerminalHostView {
            pane.leaving.isHidden = false
            leavingPane = pane
        }
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

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        leavingPane?.leaving.isHidden = true
    }
}
