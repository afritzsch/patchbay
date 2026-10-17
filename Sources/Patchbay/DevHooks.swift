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
            guard let view = mainWindow?.contentView?.superview,
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
