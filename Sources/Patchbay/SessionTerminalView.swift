import AppKit
import SwiftTerm

/// SwiftTerm's local-process terminal, reporting output, keyboard input and bells to its session.
final class SessionTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?
    var onInput: (() -> Void)?
    var onBell: (() -> Void)?
    /// The pane or overview hosts that want to show this terminal, oldest first (see `TerminalHostView`).
    var hosts: [TerminalHostView.WeakHost] = []

    func applyStyle(fontSize: CGFloat) {
        font = NSFont(name: "SF Mono", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        nativeBackgroundColor = Theme.terminalBackground
        nativeForegroundColor = Theme.terminalForeground
        caretColor = NSColor.systemOrange
        selectedTextBackgroundColor = NSColor(calibratedRed: 0.30, green: 0.36, blue: 0.48, alpha: 1)
        optionAsMetaKey = false
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }

    /// The terminal's own replies (focus reports, status queries) aren't user input. This relies on SwiftTerm
    /// sending them through `send(source: Terminal)` into `send(source: TerminalView)`; check after an update.
    private var sendingResponse = false

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        sendingResponse = true
        defer { sendingResponse = false }
        super.send(source: source, data: data)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        if !sendingResponse { onInput?() }
    }

    override func bell(source: Terminal) {
        onBell?()
    }
}

enum Theme {
    static let terminalBackground = NSColor(calibratedRed: 0.105, green: 0.110, blue: 0.130, alpha: 1)
    static let terminalForeground = NSColor(calibratedRed: 0.88, green: 0.89, blue: 0.91, alpha: 1)
}
