import AppKit

/// The questions the app asks before doing something drastic. They stay out of `SessionStore`'s own methods,
/// so those never wait for a click that an agent driving the app, or a test, can't give.
@MainActor
enum Ask {
    /// Shows an alert and returns the index of the button clicked.
    static func choose(_ message: String, _ info: String, buttons: [String]) -> Int {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        for button in buttons { alert.addButton(withTitle: button) }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func confirm(_ message: String, _ info: String, action: String) -> Bool {
        choose(message, info, buttons: [action, "Cancel"]) == 0
    }
}

/// Store actions for the UI that ask first.
extension SessionStore {
    /// Asks before closing sessions that are still doing something.
    func confirmAndClose(_ sessions: [TerminalSession]) {
        if sessions.count == 1, let session = sessions.first, let git = session.git, git.isOwnWorktree,
           !self.sessions.contains(where: { $0 !== session && $0.git?.root == git.root }) {
            return confirmAndClose(session, worktree: git)
        }
        let running = sessions.filter { $0.isBusy || $0.agent != nil }
        if sessions.count == 1, let session = running.first {
            let info = session.agent.map { "\($0.name) is still running in this session." }
                ?? "A command is still running in this session."
            guard Ask.confirm("Close “\(session.displayName)”?", info, action: "Close") else { return }
        } else if !running.isEmpty {
            let info = "\(running.count) of them are still running an agent or a command."
            guard Ask.confirm("Close \(sessions.count) sessions?", info, action: "Close All") else { return }
        }
        for session in sessions { close(session) }
    }

    func confirmAndClose(_ session: TerminalSession) { confirmAndClose([session]) }

    /// The last session in a worktree this app made: close it and keep the worktree, or delete that too.
    private func confirmAndClose(_ session: TerminalSession, worktree git: GitInfo) {
        var info = "It has its own worktree on branch \(git.branch)."
        if git.changed > 0 { info += " Deleting it loses \(git.changed) uncommitted change\(git.changed == 1 ? "" : "s")." }
        if let agent = session.agent { info += "\n\n\(agent.name) is still running." }
        else if session.isBusy { info += "\n\nA command is still running." }
        let choice = Ask.choose("Close “\(session.displayName)”?", info,
                                buttons: ["Close", "Close and Delete Worktree", "Cancel"])
        guard choice < 2 else { return }
        close(session)
        guard choice == 1 else { return }
        let path = git.root
        Task {
            if let error = await inBackground({ Git.removeWorktree(path) }) {
                _ = Ask.choose("Couldn't delete the worktree", error, buttons: ["OK"])
            }
        }
    }

    func confirmAndBringIn(_ external: ExternalSession, splitting target: UUID?, zone: DropZone) {
        var info = "Claude Code will quit in \(external.hostApp ?? "the other terminal") and the conversation "
            + "continues here (claude --resume)."
        if external.busy {
            info += "\n\nClaude is working right now; moving it interrupts the current step. You can ask it to carry on afterwards."
        }
        guard Ask.confirm("Move “\(external.displayName)” into Patchbay?", info, action: "Move") else { return }
        bringIn(external, splitting: target, zone: zone)
    }

    /// Opens a session for each folder dropped from Finder or a terminal's title-bar folder icon (a file opens
    /// its folder). A folder where Claude already runs in another terminal offers to bring that session in.
    func open(droppedURLs urls: [URL], splitting target: UUID? = nil, zone: DropZone = .right) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            let folder = isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path
            if let external = externalSession(in: folder) {
                let choice = Ask.choose(
                    "Claude Code is running in “\(external.displayName)” in \(external.hostApp ?? "another terminal")",
                    "Move that session here, or start a new one in this folder?",
                    buttons: ["Move It Here", "New Session", "Cancel"])
                if choice == 0 { bringIn(external, splitting: target, zone: zone) }
                if choice != 1 { continue }
            }
            newSession(directory: folder, agent: lastAgent, splitting: target, zone: zone)
        }
    }

    /// Handles something dragged into a sidebar section (`group`, nil for the ungrouped one) at `index`.
    /// A selected session brings the rest of the selection along.
    func dropInSidebar(at index: Int, group: UUID?) {
        defer { dragged = nil }
        switch dragged {
        case .session(let id):
            move(multiSelection.contains(id) ? sessions.map(\.id).filter(multiSelection.contains) : [id], to: group, at: index)
        case .external(let external):
            // After the drop has finished, so the question isn't asked mid-drop.
            DispatchQueue.main.async { self.confirmAndBringIn(external, splitting: nil, zone: .right) }
        case nil:
            break
        }
    }
}

/// Puts text on the clipboard.
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
