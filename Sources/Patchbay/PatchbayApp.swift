import SwiftUI
import UserNotifications

@main
struct PatchbayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Patchbay", id: "main") {
            ContentView()
                .environment(appDelegate.store)
                .frame(minWidth: 760, minHeight: 420)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { AppCommands(store: appDelegate.store) }

        Settings {
            SettingsView()
                .environment(appDelegate.store)
        }
    }
}

private struct AppCommands: Commands {
    let store: SessionStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { store.showNewSessionSheet = true }
                .keyboardShortcut("n")
            Button("New Shell Here") { store.newShellHere() }
                .keyboardShortcut("t")
            Divider()
            // No ⌘W here: menu shortcuts fire in every window. AppDelegate's key monitor takes ⌘W in the main window.
            Button("Close Session") {
                if let session = store.selectedSession { store.confirmAndClose(session) }
            }
            .disabled(store.selectedSession == nil)
        }
        CommandMenu("Pane") {
            Button("Split Right") { store.split(.right) }
                .keyboardShortcut("d")
            Button("Split Down") { store.split(.bottom) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Next Pane") { store.focusAdjacentPane(1) }
                .keyboardShortcut("]")
            Button("Previous Pane") { store.focusAdjacentPane(-1) }
                .keyboardShortcut("[")
            Divider()
            Button("Even Out Panes") { store.equalizePanes() }
                .keyboardShortcut("=", modifiers: [.command, .control])
                .disabled(store.paneCount < 2)
            Button("Remove Pane") {
                if let id = store.selectedID { store.closePane(id) }
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(store.paneCount < 2)
        }
        CommandMenu("Session") {
            Button("Next Needing Attention") { store.selectNextNeedingAttention() }
                .keyboardShortcut("j")
            Button("Next Session") { store.selectAdjacent(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Session") { store.selectAdjacent(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            // Not disabled while nothing is asked: SwiftUI updates the menu late, which would swallow the first ⌘Y.
            Button("Allow Request") { store.selectedSession?.answerApproval(allow: true) }
                .keyboardShortcut("y")
            Button("Deny Request") { store.selectedSession?.answerApproval(allow: false) }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Divider()
            Button("Rename…") { store.renamingID = store.selectedID }
                .keyboardShortcut("r")
                .disabled(store.selectedSession == nil)
            Divider()
            ForEach(0..<9, id: \.self) { index in
                Button("Session \(index + 1)") { store.select(index: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
        CommandGroup(before: .toolbar) {
            Button(store.showOverview ? "Hide Overview" : "Show Overview") { store.showOverview.toggle() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button(store.showHistory ? "Hide History" : "Show History") {
                store.showHistory.toggle()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Bigger") { store.fontSize = min(store.fontSize + 1, Preferences.fontSizes.upperBound) }
                .keyboardShortcut("=")
            Button("Smaller") { store.fontSize = max(store.fontSize - 1, Preferences.fontSizes.lowerBound) }
                .keyboardShortcut("-")
            Button("Actual Size") { store.fontSize = Preferences.defaultFontSize }
                .keyboardShortcut("0")
            Divider()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// `NSApp.delegate` is SwiftUI's adaptor, not this object.
    private(set) static weak var shared: AppDelegate?
    let store: SessionStore
    weak var mainWindow: NSWindow? {
        didSet {
            guard mainWindow !== oldValue else { return }
            firstResponderObservation = mainWindow?.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
                MainActor.assumeIsolated { self?.store.terminalBecameFirstResponder(window.firstResponder) }
            }
        }
    }
    private var firstResponderObservation: NSKeyValueObservation?

    override init() {
        Preferences.register()
        store = SessionStore()
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        startDevHooks()
        // ⌘W closes the session, not the window, while the main window is in front.
        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "w",
                  event.window != nil, event.window === self.mainWindow,
                  event.window?.attachedSheet == nil,
                  let session = self.store.selectedSession else { return event }
            self.store.confirmAndClose(session)
            return nil
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.appBecameActive()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = store.sessions.filter(\.isBusy)
        guard !busy.isEmpty else { return .terminateNow }
        let info = "\(busy.count == 1 ? "1 session is" : "\(busy.count) sessions are") still busy: "
            + busy.map(\.displayName).joined(separator: ", ")
            + ". Sessions reopen on the next launch, but running work stops."
        return Ask.confirm("Quit Patchbay?", info, action: "Quit") ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.save()
        store.history.flush()
        for session in store.sessions { session.close() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let idString = response.notification.request.content.userInfo["session"] as? String
        await MainActor.run {
            NSApp.activate()
            if let idString, let id = UUID(uuidString: idString), store.session(id) != nil {
                store.show(id)
            }
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
