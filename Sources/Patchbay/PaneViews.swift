import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A session dragged from the sidebar or a pane header.
    static let terminalSession = UTType(exportedAs: "app.patchbay.session")
}

extension NSPasteboard.PasteboardType {
    static let terminalSession = NSPasteboard.PasteboardType(UTType.terminalSession.identifier)
}

extension SessionStore {
    /// Drag item for a session; drop targets read `dragged`, the item marks the drag as ours.
    func dragItem(for session: TerminalSession) -> NSItemProvider {
        dragged = .session(session.id)
        let provider = NSItemProvider()
        provider.suggestedName = session.displayName
        let data = Data(session.displayName.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.terminalSession.identifier,
                                            visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

/// Renders a layout tree: a pane or a split of further nodes.
struct LayoutNodeView: View {
    @Environment(SessionStore.self) private var store
    let node: PaneLayout

    var body: some View {
        switch node {
        case .pane(let id):
            if let session = store.session(id) {
                PaneView(session: session)
            } else {
                Color(nsColor: Theme.terminalBackground)
            }
        case .split(let id, let axis, let children, let fractions):
            SplitNodeView(id: id, axis: axis, children: children, fractions: fractions)
        }
    }
}

/// Children laid out along an axis with draggable dividers between them.
private struct SplitNodeView: View {
    @Environment(SessionStore.self) private var store
    let id: UUID
    let axis: SplitAxis
    let children: [PaneLayout]
    let fractions: [Double]

    static let dividerThickness: CGFloat = 5
    static let minimumPaneLength: CGFloat = 120

    var body: some View {
        GeometryReader { geometry in
            let total = axis == .horizontal ? geometry.size.width : geometry.size.height
            let available = max(total - Self.dividerThickness * CGFloat(children.count - 1), 1)
            let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                ForEach(Array(children.enumerated()), id: \.element.nodeID) { index, child in
                    let length = available * CGFloat(fractions.indices.contains(index) ? fractions[index] : 0)
                    LayoutNodeView(node: child)
                        .frame(width: axis == .horizontal ? length : nil, height: axis == .vertical ? length : nil)
                    if index < children.count - 1 {
                        divider(after: index, available: available)
                    }
                }
            }
        }
    }

    private func divider(after index: Int, available: CGFloat) -> some View {
        ResizeHandle(axis: axis, thickness: Self.dividerThickness, background: Color(nsColor: Theme.terminalBackground),
                     idleOpacity: 0.10, fractions: fractions, index: index, length: available,
                     minimum: Self.minimumPaneLength) {
            store.setFractions($0, forSplit: id)
        } onEnded: {
            store.save()
        } onDoubleClick: {
            store.setFractions(PaneLayout.even(children.count), forSplit: id)
            store.save()
        }
    }
}

/// Moves the boundary after `index` by `delta` (a fraction of the whole), keeping both neighbours at least
/// `minimum` and their combined share unchanged.
func resized(_ fractions: [Double], at index: Int, by delta: Double, minimum: Double) -> [Double] {
    guard fractions.indices.contains(index + 1) else { return fractions }
    let pair = fractions[index] + fractions[index + 1]
    let floor = min(minimum, pair / 2)
    let first = min(max(fractions[index] + delta, floor), pair - floor)
    var updated = fractions
    updated[index] = first
    updated[index + 1] = pair - first
    return updated
}

/// A draggable gap between panes or overview cards. `axis` is the axis of the stack it sits in, so a
/// horizontal stack gets a vertical line that resizes columns. It moves the boundary after `fractions[index]`,
/// shares of `length` points, keeping both sides at least `minimum` points.
struct ResizeHandle: View {
    let axis: SplitAxis
    let thickness: CGFloat
    var background: Color = .clear
    var idleOpacity: Double = 0
    let fractions: [Double]
    let index: Int
    let length: CGFloat
    let minimum: CGFloat
    let onChanged: ([Double]) -> Void
    /// Also called when the drag is cancelled, which DragGesture's own onEnded misses.
    var onEnded: () -> Void = {}
    let onDoubleClick: () -> Void
    @GestureState private var dragging = false
    @State private var hovering = false
    @State private var start: [Double]?

    var body: some View {
        ZStack {
            background
            Rectangle()
                .fill(Color.primary.opacity(dragging ? 0.40 : hovering ? 0.22 : idleOpacity))
                .frame(width: axis == .horizontal ? (dragging || hovering ? 2 : 1) : nil,
                       height: axis == .vertical ? (dragging || hovering ? 2 : 1) : nil)
        }
        .frame(width: axis == .horizontal ? thickness : nil, height: axis == .vertical ? thickness : nil)
        .contentShape(.rect)
        .pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($dragging) { _, dragging, _ in dragging = true }
                .onChanged { value in
                    let translation = axis == .horizontal ? value.translation.width : value.translation.height
                    let from = start ?? fractions
                    start = from
                    onChanged(resized(from, at: index, by: Double(translation / length), minimum: Double(minimum / length)))
                }
        )
        .onChange(of: dragging) {
            if !dragging {
                start = nil
                onEnded()
            }
        }
        .onTapGesture(count: 2, perform: onDoubleClick)
        .help("Drag to resize, double-click to even out")
    }
}

/// One session on screen: a header (drag it to move the pane) above the terminal.
struct PaneView: View {
    @Environment(SessionStore.self) private var store
    let session: TerminalSession

    private var isFocused: Bool { store.selectedID == session.id }
    private var isSplit: Bool { store.paneCount > 1 }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(session: session, isFocused: isFocused, canClose: isSplit)
            TerminalContainer(session: session, isFocused: isFocused, isDimmed: isSplit && !isFocused)
        }
        .background(Color(nsColor: Theme.terminalBackground))
    }
}

private struct PaneHeader: View {
    @Environment(SessionStore.self) private var store
    let session: TerminalSession
    let isFocused: Bool
    let canClose: Bool

    var body: some View {
        HStack(spacing: 7) {
            StatusIcon(session: session)
                .font(.system(size: 11))
            Text(session.displayName)
                .fontWeight(isFocused ? .semibold : .regular)
                .lineLimit(1)
                .layoutPriority(1)
            Text(session.statusLabel)
                .foregroundStyle(session.statusColor)
                .lineLimit(1)
            ElapsedText(since: session.statusSince)
                .foregroundStyle(.secondary)
            GitBadge(session: session).foregroundStyle(.secondary)
            if let detail = session.detailLine {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if canClose {
                Button {
                    store.closePane(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help("Remove pane (⌥⌘W); the session keeps running in the sidebar")
            }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(isFocused ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.05), ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.35)).frame(height: 1)
        }
        .environment(\.colorScheme, .dark)
        .contentShape(.rect)
        .onTapGesture { store.selectedID = session.id }
        .onDrag { store.dragItem(for: session) }
        .contextMenu { SessionMenu(session: session) }
        .help("Drag onto another pane to move it there")
    }
}

/// Hosts a session's terminal view and accepts drops. Terminal views live as long as their session, so
/// moving a pane only re-parents the view.
struct TerminalContainer: NSViewRepresentable {
    @Environment(SessionStore.self) private var store
    let session: TerminalSession
    let isFocused: Bool
    /// Shades an unfocused pane. Drawn by the host: a SwiftUI overlay becomes a view in front of it that eats drops.
    var isDimmed = false
    /// Whether drops on an edge split the pane. Off in the overview, where cards aren't panes.
    var splitsOnDrop = true

    func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView()
    }

    func updateNSView(_ view: TerminalHostView, context: Context) {
        view.sessionID = session.id
        view.store = store
        view.dim.isHidden = !isDimmed
        view.splitsOnDrop = splitsOnDrop
        view.show(session.terminal, focus: isFocused)
    }
}

final class TerminalHostView: NSView {
    var sessionID: UUID?
    weak var store: SessionStore?
    var splitsOnDrop = true
    private let inset = NSSize(width: 8, height: 6)
    let dim = OverlayView(fill: NSColor.black.withAlphaComponent(0.18))
    /// Shown while this pane's session is dragged from the sidebar: dropping it elsewhere takes it out of here.
    let leaving = OverlayView(fill: NSColor.black.withAlphaComponent(0.55), label: "Moves out of this pane")
    private let highlight = OverlayView(fill: NSColor.controlAccentColor.withAlphaComponent(0.22),
                                        border: NSColor.controlAccentColor.withAlphaComponent(0.8))
    private var zone: DropZone? {
        didSet { updateHighlight() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.terminalBackground.cgColor
        dim.isHidden = true
        leaving.isHidden = true
        highlight.isHidden = true
        addSubview(dim)
        addSubview(leaving)
        addSubview(highlight)
        registerForDraggedTypes([.terminalSession, .fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var terminal: NSView? { subviews.first { !($0 is OverlayView) } }
    /// The terminal this host shows, which may for a moment sit in another host.
    private weak var claimed: SessionTerminalView?
    private var wantsFocus = false

    /// A host in a terminal's `hosts`. When the main area switches between panes and the overview, SwiftUI makes
    /// the new host before it last updates the old one, so both ask for the same terminal; it goes to the newest
    /// host in the window.
    struct WeakHost {
        weak var host: TerminalHostView?
    }

    func show(_ terminal: SessionTerminalView, focus: Bool) {
        if claimed !== terminal {
            if let claimed { Self.unclaim(claimed, by: self) }
            claimed = terminal
            Self.claim(terminal, by: self)
        }
        Self.settle(terminal)
        wantsFocus = focus
        if focus {
            DispatchQueue.main.async { [weak self] in self?.focusTerminal() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let claimed else { return }
        if window != nil { Self.claim(claimed, by: self) } // now the newest
        Self.settle(claimed)
        // A newly made host is often not in the window yet when SwiftUI first updates it.
        if window != nil, wantsFocus {
            DispatchQueue.main.async { [weak self] in self?.focusTerminal() }
        }
    }

    private static func claim(_ terminal: SessionTerminalView, by host: TerminalHostView) {
        unclaim(terminal, by: host)
        terminal.hosts.append(WeakHost(host: host))
    }

    private static func unclaim(_ terminal: SessionTerminalView, by host: TerminalHostView) {
        terminal.hosts.removeAll { $0.host == nil || $0.host === host }
    }

    /// Puts the terminal in its newest claimant that is in a window, or else its newest claimant.
    private static func settle(_ terminal: SessionTerminalView) {
        let hosts = terminal.hosts.compactMap(\.host)
        guard let owner = hosts.last(where: { $0.window != nil }) ?? hosts.last else { return }
        owner.attach(terminal)
    }

    private func attach(_ terminal: NSView) {
        guard terminal.superview !== self else { return }
        self.terminal?.removeFromSuperview()
        terminal.removeFromSuperview()
        terminal.autoresizingMask = []
        addSubview(terminal, positioned: .below, relativeTo: dim)
        layoutTerminal()
    }

    private func focusTerminal() {
        guard wantsFocus, let terminal, let window, window.firstResponder !== terminal else { return }
        window.makeFirstResponder(terminal)
    }

    override func layout() {
        super.layout()
        dim.frame = bounds
        leaving.frame = bounds
        layoutTerminal()
        updateHighlight()
    }

    /// Sized by hand rather than by autoresizing: a host starts out zero-sized, and insetting that gives a null
    /// rect that autoresizing never moves back on screen.
    private func layoutTerminal() {
        guard let terminal else { return }
        let frame = NSRect(x: inset.width, y: inset.height,
                           width: max(bounds.width - 2 * inset.width, 0),
                           height: max(bounds.height - 2 * inset.height, 0))
        if terminal.frame != frame { terminal.frame = frame }
    }

    // MARK: Drop target

    private func draggedSession(_ info: NSDraggingInfo) -> DragPayload? {
        // `draggingSource` is only set for drags that started in this app; the type tells ours from text drags,
        // since `dragged` may be left over from a cancelled drag.
        guard info.draggingSource != nil,
              info.draggingPasteboard.types?.contains(.terminalSession) == true else { return nil }
        return store?.dragged
    }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func zone(for info: NSDraggingInfo) -> DropZone? {
        guard let sessionID else { return nil }
        guard splitsOnDrop else {
            // Only files, typed into the terminal.
            return draggedSession(info) == nil && !droppedFiles(info).isEmpty ? .center : nil
        }
        let zone = Self.zone(at: convert(info.draggingLocation, from: nil), in: bounds)
        if let dragged = draggedSession(info) {
            return dragged == .session(sessionID) ? nil : zone // Dropping a pane on itself does nothing.
        }
        // Files: the centre types their paths into the terminal, an edge opens a session for the folder.
        return droppedFiles(info).isEmpty ? nil : zone
    }

    nonisolated static func zone(at point: NSPoint, in bounds: NSRect) -> DropZone {
        guard bounds.width > 0, bounds.height > 0 else { return .center }
        let x = (point.x - bounds.minX) / bounds.width
        let y = 1 - (point.y - bounds.minY) / bounds.height // 0 at the top
        let distances: [(DropZone, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        let nearest = distances.min { $0.1 < $1.1 }!
        return nearest.1 < 0.25 ? nearest.0 : .center
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        zone = zone(for: sender)
        return zone == nil ? [] : (draggedSession(sender) != nil ? .move : .copy)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        zone = nil
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        zone = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            zone = nil
            store?.dragged = nil
        }
        guard let target = sessionID, let store, let zone = zone(for: sender) else { return false }
        switch draggedSession(sender) {
        case .session(let id):
            store.drop(session: id, on: target, zone: zone)
            return true
        case .external(let external):
            // After the drag has finished, so the confirmation isn't shown mid-drop.
            DispatchQueue.main.async { store.confirmAndBringIn(external, splitting: target, zone: zone) }
            return true
        case nil:
            break
        }
        let files = droppedFiles(sender)
        guard let first = files.first else { return false }
        if zone == .center {
            let paths = files.map { Self.shellEscaped($0.path) }.joined(separator: " ")
            store.session(target)?.terminal.send(txt: paths + " ")
        } else {
            store.open(droppedURLs: [first], splitting: target, zone: zone)
        }
        return true
    }

    /// Backslash-escapes a path the way Terminal does for dropped files.
    nonisolated static func shellEscaped(_ path: String) -> String {
        let special = Set(" \t\\'\"`$&|;<>()[]{}*?!#~=%^")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    private func updateHighlight() {
        guard let zone else {
            highlight.isHidden = true
            return
        }
        var rect = bounds
        switch zone {
        case .left: rect.size.width /= 2
        case .right: rect.size.width /= 2; rect.origin.x += rect.width
        case .top: rect.size.height /= 2; rect.origin.y += rect.height
        case .bottom: rect.size.height /= 2
        case .center: break
        }
        highlight.frame = rect.insetBy(dx: 4, dy: 4)
        highlight.isHidden = false
    }
}

/// A translucent box over a terminal: the dimming of an unfocused pane, the pane a drag takes its session out of,
/// or where a drop will land. Never takes clicks or drops itself.
final class OverlayView: NSView {
    private var label: NSTextField?

    init(fill: NSColor, border: NSColor? = nil, label text: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        if let border {
            layer?.borderColor = border.cgColor
            layer?.borderWidth = 2
            layer?.cornerRadius = 6
        }
        if let text {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .white
            addSubview(label)
            self.label = label
        }
    }

    override func layout() {
        super.layout()
        guard let label else { return }
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: (bounds.width - label.frame.width) / 2, y: (bounds.height - label.frame.height) / 2))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
