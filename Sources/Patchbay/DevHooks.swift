import AppKit

/// Remote control for scripts/dev-mcp.swift. Active only in the test copy it launches with `PATCHBAY_DEV_DIR` set.
extension AppDelegate {
    func startDevHooks() {
        guard let dir = ProcessInfo.processInfo.environment["PATCHBAY_DEV_DIR"] else { return }
        setvbuf(stdout, nil, _IOLBF, 0)  // print() reaches the log file line by line, not when the buffer fills
        _ = DistributedNotificationCenter.default().addObserver(
            forName: .init("\(Bundle.main.bundleIdentifier ?? "Patchbay").dev"), object: nil, queue: .main
        ) { [weak self] note in
            let action = note.userInfo?["action"] as? String
            let arg = note.userInfo?["arg"] as? String ?? ""
            MainActor.assumeIsolated { self?.runDevAction(action, arg, dir: dir) }
        }
    }

    private func runDevAction(_ action: String?, _ arg: String, dir: String) {
        switch action {
        case "snapshot":
            guard let view = (mainWindow?.attachedSheet ?? mainWindow)?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            // SwiftTerm paints its background on the layer, which cacheDisplay skips; redraw terminals over it.
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            for session in store.sessions where session.terminal.window != nil {
                let terminal = session.terminal
                guard let terminalRep = terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds) else { continue }
                terminal.cacheDisplay(in: terminal.bounds, to: terminalRep)
                var rect = view.convert(terminal.bounds, from: terminal)
                if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
                terminal.nativeBackgroundColor.setFill()
                rect.fill()
                terminalRep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
            NSGraphicsContext.current = nil
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "snapshot.png"))
        case "drop": // "<session> <target> <left|right|top|bottom|center>", sessions numbered as in the sidebar from 1
            let parts = arg.split(separator: " ")
            guard parts.count == 3, let from = Int(parts[0]).map({ $0 - 1 }), let to = Int(parts[1]).map({ $0 - 1 }),
                  store.sessions.indices.contains(from), store.sessions.indices.contains(to),
                  let zone = DropZone(rawValue: String(parts[2]))
            else { return print("dev: bad drop \(arg)") }
            store.drop(session: store.sessions[from].id, on: store.sessions[to].id, zone: zone)
        case "layout":
            // The pane tree with sessions numbered as in the sidebar, e.g. H[1:0.50 V[2:0.50 3:0.50]:0.50], then each
            // terminal's frame in window points.
            let numbers = Dictionary(uniqueKeysWithValues: store.sessions.enumerated().map { ($1.id, "\($0 + 1)") })
            var lines = [store.layout.map { describe($0, numbers) } ?? "no panes"]
            for (index, session) in store.sessions.enumerated() where session.terminal.window != nil {
                lines.append("terminal \(index + 1): \(session.terminal.convert(session.terminal.bounds, to: nil))")
            }
            try? lines.joined(separator: "\n").write(to: URL(fileURLWithPath: dir).appending(path: "layout.txt"),
                                                      atomically: true, encoding: .utf8)
        case "type":
            store.selectedSession?.terminal.send(txt: arg)
        case "menu":
            guard let (menu, index) = NSApp.mainMenu.flatMap({ find(arg, in: $0) }) else {
                return print("dev: no menu item titled \(arg)")
            }
            menu.performActionForItem(at: index)
        default:
            print("dev: unknown action \(action ?? "nil")")
        }
    }

    /// H[…] is a row, V[…] a column; each child is followed by its share.
    private func describe(_ node: PaneLayout, _ numbers: [UUID: String]) -> String {
        switch node {
        case .pane(let id): numbers[id] ?? "?"
        case .split(_, let axis, let children, let fractions):
            "\(axis == .horizontal ? "H" : "V")[" + zip(children, fractions).map {
                "\(describe($0, numbers)):\(String(format: "%.2f", $1))"
            }.joined(separator: " ") + "]"
        }
    }

    private func find(_ title: String, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if let submenu = item.submenu {
                if let found = find(title, in: submenu) { return found }
            } else if item.title == title {
                return (menu, index)
            }
        }
        return nil
    }
}
