import SwiftUI

struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @State private var renameText = ""

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 420)
        } detail: {
            Group {
                if store.mode == .history {
                    HistoryView()
                } else if store.showOverview {
                    OverviewView()
                } else if let layout = store.layout {
                    LayoutNodeView(node: layout)
                        // Terminal colour up to the window top, without a toolbar strip over the panes.
                        .background(Color(nsColor: Theme.terminalBackground).ignoresSafeArea())
                        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                } else {
                    EmptyStateView()
                }
            }
            .toolbar { toolbar }
            .inspector(isPresented: Binding(
                get: { store.selectedChange != nil },
                set: { if !$0 { store.selectedChange = nil } }
            )) {
                if let selection = store.selectedChange {
                    DiffView(selection: selection)
                        .inspectorColumnWidth(min: 300, ideal: 500, max: 900)
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(store.mode == .panes ? store.selectedSession?.abbreviatedCwd ?? "" : "")
        .sheet(isPresented: $store.showNewSessionSheet) {
            NewSessionSheet()
        }
        // renamingID is a session's or a group's.
        .alert(renamingGroup != nil ? "Rename Group" : "Rename Session", isPresented: Binding(
            get: { store.renamingID != nil },
            set: { if !$0 { store.renamingID = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let session = store.sessions.first(where: { $0.id == store.renamingID }) {
                    store.rename(session, to: renameText)
                } else if let group = renamingGroup {
                    store.renameGroup(group.id, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if renamingGroup == nil { Text("Leave empty to name it after its folder.") }
        }
        .onChange(of: store.renamingID) {
            renameText = renamingGroup?.name ?? store.sessions.first { $0.id == store.renamingID }?.customName ?? ""
        }
        .background(WindowAccessor())
    }

    private var renamingGroup: SessionGroup? { store.groups.first { $0.id == store.renamingID } }

    private var title: String {
        switch store.mode {
        case .panes: store.selectedSession?.displayName ?? "Patchbay"
        case .overview: "Overview"
        case .history: "History"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if store.attentionCount > 0 {
                Button {
                    store.selectNextNeedingAttention()
                } label: {
                    Label("\(store.attentionCount) need you", systemImage: "bell.badge.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                }
                .help("Jump to the next session that needs attention (⌘J)")
            }
            if store.showOverview && store.sessions.count > 1 {
                Menu {
                    Picker("Columns", selection: Bindable(store).overviewColumns) {
                        Text("Fit to Window").tag(0)
                        Divider()
                        ForEach(1...min(store.sessions.count, 6), id: \.self) { n in
                            Text(n == 1 ? "1 Column" : "\(n) Columns").tag(n)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Even Out Sizes") {
                        store.overviewColumnFractions = []
                        store.overviewRowFractions = []
                        store.saveOverviewSizes()
                    }
                } label: {
                    Label("Columns", systemImage: "rectangle.split.3x3")
                }
                .help("Overview columns; drag the gaps between cards to resize them")
            }
            Button {
                store.showOverview.toggle()
            } label: {
                Label("Overview", systemImage: store.showOverview ? "rectangle.inset.filled" : "square.grid.2x2")
            }
            .help("Toggle the overview of all sessions (⇧⌘O)")
            Button {
                if store.showHistory { store.mode = .panes } else { store.showHistory(for: nil) }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .help("Activity history (⇧⌘H)")
            Menu {
                Button("New Session…") { store.showNewSessionSheet = true }
                Button("New Shell Here") { store.newShellHere() }
                Divider()
                Button("Split Right") { store.split(.right) }
                Button("Split Down") { store.split(.bottom) }
            } label: {
                Label("New Session", systemImage: "plus")
            } primaryAction: {
                store.showNewSessionSheet = true
            }
            .help("New session (⌘N), new shell in this folder (⌘T)")
        }
    }
}

struct EmptyStateView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("No Sessions", systemImage: "terminal")
        } description: {
            Text("Start a Claude Code session or a plain shell, or drop a folder here. Drag sessions from the sidebar onto a pane's edge to work side by side.")
        } actions: {
            Button("New Session…") { store.showNewSessionSheet = true }
                .buttonStyle(.borderedProminent)
            Button("New Shell") { store.newSession(directory: NSHomeDirectory(), agent: nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadFileURLs(from: providers) { store.open(droppedURLs: $0) }
            return true
        }
    }
}

/// Hands the main window to the app delegate (for ⌘W handling).
private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ReportingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReportingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { AppDelegate.shared?.mainWindow = window }
        }
    }
}
