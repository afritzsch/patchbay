import SwiftUI

/// How a session's status is shown in the sidebar, header and overview.
extension TerminalSession {
    var statusLabel: String {
        switch status {
        case .starting: "Starting"
        case .idle: "Idle"
        case .running: "Running"
        case .claudeReady: "Waiting for prompt"
        case .claudeWorking: currentTool.map { "Working · \($0)" } ?? "Working"
        case .claudeNeedsInput: "Needs your input"
        case .claudeDone: "Done"
        case .exited(let code): code.map { "Exited (\($0))" } ?? "Exited"
        }
    }

    var statusColor: Color {
        switch status {
        case .starting, .idle, .exited: .secondary
        case .running: .blue
        case .claudeReady: .teal
        case .claudeWorking: .purple
        case .claudeNeedsInput: .orange
        case .claudeDone: .green
        }
    }

    var statusSymbol: String {
        switch status {
        case .starting: "hourglass"
        case .idle: "terminal"
        case .running: "play.circle.fill"
        case .claudeReady: "sparkle"
        case .claudeWorking: "sparkles"
        case .claudeNeedsInput: "exclamationmark.bubble.fill"
        case .claudeDone: "checkmark.circle.fill"
        case .exited: "xmark.circle"
        }
    }

    /// The most useful one-line detail: what's running, what Claude asked, or what it was asked.
    var detailLine: String? {
        if case .running(let command) = status { return command }
        if status == .claudeNeedsInput, let message { return message }
        if let message, unseen { return message }
        if isClaude {
            if let lastPrompt { return lastPrompt }
            if !title.isEmpty { return title }
        }
        return nil
    }

    var abbreviatedCwd: String {
        (cwd as NSString).abbreviatingWithTildeInPath
    }
}

struct StatusIcon: View {
    let session: TerminalSession

    var body: some View {
        Image(systemName: session.statusSymbol)
            .foregroundStyle(session.statusColor)
            .symbolEffect(.pulse, options: .repeating, isActive: session.status == .claudeWorking || session.status == .claudeNeedsInput)
            .frame(width: 18)
    }
}

/// "12s", "4m", "2h" since the status last changed, refreshed while shown.
struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .monospacedDigit()
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

/// "⎇ main ●3 ↑1 ↓2": branch, changed files, commits ahead of and behind the upstream. Font and colour come from the caller.
struct GitBadge: View {
    let git: GitInfo

    var body: some View {
        HStack(spacing: 4) {
            Label(git.branch, systemImage: "arrow.triangle.branch")
                .lineLimit(1)
            if git.changed > 0 { Text("●\(git.changed)").foregroundStyle(.orange) }
            if git.ahead > 0 { Text("↑\(git.ahead)") }
            if git.behind > 0 { Text("↓\(git.behind)") }
        }
        .fixedSize()
    }
}
