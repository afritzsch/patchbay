import SwiftUI

/// How a session's status is shown in the sidebar, header and overview.
extension SessionState {
    var statusLabel: String {
        switch status {
        case .starting: "Starting"
        case .idle: "Idle"
        case .running: "Running"
        case .agentReady: "Waiting for prompt"
        case .agentWorking where runningSubagents > 0: "Waiting for agent"
        case .agentWorking: currentTool.map { "Working · \($0)" } ?? "Working"
        case .agentNeedsInput: "Needs your input"
        case .agentDone: "Done"
        case .exited(let code): code.map { "Exited (\($0))" } ?? "Exited"
        }
    }

    var statusColor: Color {
        switch status {
        case .starting, .idle, .exited: .secondary
        case .running: .blue
        case .agentReady: .teal
        case .agentWorking: .purple
        case .agentNeedsInput: .orange
        case .agentDone: .green
        }
    }

    var statusSymbol: String {
        switch status {
        case .starting: "hourglass"
        case .idle: "terminal"
        case .running: "play.circle.fill"
        case .agentReady: "sparkle"
        case .agentWorking: "sparkles"
        case .agentNeedsInput: "exclamationmark.bubble.fill"
        case .agentDone: "checkmark.circle.fill"
        case .exited: "xmark.circle"
        }
    }

}

extension TerminalSession {
    /// The most useful one-line detail: what's running, what Claude asked, or what it was asked.
    var detailLine: String? {
        if case .running(let command) = state.status { return command }
        if state.status == .agentNeedsInput, let message = state.message { return message }
        if let message = state.message, state.unseen { return message }
        if state.agent != nil {
            if let lastPrompt = state.lastPrompt { return lastPrompt }
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// What identifies the session in a list: its name if it has one, else what the agent was asked, else the folder.
    /// Sessions in one folder all look alike by `displayName`.
    var rowTitle: String {
        if let customName, !customName.isEmpty { return customName }
        if state.agent != nil, let topic = state.lastPrompt ?? (title.isEmpty ? nil : title) { return topic }
        return displayName
    }

    var abbreviatedCwd: String {
        (state.cwd as NSString).abbreviatingWithTildeInPath
    }
}

struct StatusIcon: View {
    let session: TerminalSession

    var body: some View {
        Image(systemName: session.statusSymbol)
            .foregroundStyle(session.statusColor)
            .symbolEffect(.pulse, options: .repeating, isActive: session.status == .agentWorking || session.status == .agentNeedsInput)
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

    nonisolated static func format(_ interval: TimeInterval) -> String {
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
