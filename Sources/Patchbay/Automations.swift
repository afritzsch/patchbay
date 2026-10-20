import Foundation

/// A session started on a schedule: an agent with a prompt, or a shell running a command. Runs only while the
/// app is open; a run missed while it was closed or the Mac slept starts once when it's back.
struct Automation: Codable, Identifiable, Hashable {
    enum Frequency: String, Codable, CaseIterable {
        case hourly, daily, weekdays, weekly
    }

    var id = UUID()
    var name = ""
    var folder = NSHomeDirectory()
    /// An agent's id, or "shell".
    var agentID = Agent.claude.id
    /// The agent's first prompt, or the shell's command.
    var prompt = ""
    /// Claude's `--model` and `--effort`; nil for its own default.
    var model: String?
    var effort: String?
    /// Each run gets its own worktree, on a branch named after the automation and the time.
    var newWorktree = false
    var frequency = Frequency.weekdays
    /// Hourly runs use only the minute.
    var hour = 9
    var minute = 0
    /// For weekly runs; 1 is Sunday, as in `Calendar`.
    var weekday = 2
    var isEnabled = true
    /// nil while it is paused.
    var nextRun: Date?
    var lastRun: Date?
    var lastSessionID: UUID?
    /// Why the last run didn't start.
    var lastError: String?

    var title: String { name.isEmpty ? prompt : name }
    var agentName: String { Agent.named(agentID)?.name ?? "Shell" }

    /// The first time after `date` that the schedule matches.
    func nextRun(after date: Date, calendar: Calendar = .current) -> Date? {
        var match = DateComponents(minute: minute)
        if frequency != .hourly { match.hour = hour }
        if frequency == .weekly { match.weekday = weekday }
        var next = calendar.nextDate(after: date, matching: match, matchingPolicy: .nextTime)
        while frequency == .weekdays, let day = next, calendar.isDateInWeekend(day) {
            next = calendar.nextDate(after: day, matching: match, matchingPolicy: .nextTime)
        }
        return next
    }

    /// "Weekdays at 9:00 AM".
    var schedule: String {
        let time = Calendar.current.date(from: DateComponents(hour: hour, minute: minute))?
            .formatted(date: .omitted, time: .shortened) ?? ""
        return switch frequency {
        case .hourly: String(format: "Hourly at :%02d", minute)
        case .daily: "Daily at \(time)"
        case .weekdays: "Weekdays at \(time)"
        case .weekly: "Every \(Calendar.current.weekdaySymbols[weekday - 1]) at \(time)"
        }
    }
}

extension SessionStore {
    /// Opens the automation sheet for a new one in the focused session's folder.
    func newAutomation() {
        editingAutomation = Automation(folder: selectedSession?.cwd ?? NSHomeDirectory())
    }

    /// Adds or replaces an automation, scheduling its next run from now.
    func saveAutomation(_ automation: Automation) {
        var automation = automation
        automation.nextRun = automation.isEnabled ? automation.nextRun(after: Date()) : nil
        if let index = automations.firstIndex(where: { $0.id == automation.id }) {
            automations[index] = automation
        } else {
            automations.append(automation)
        }
    }

    func deleteAutomation(_ id: UUID) {
        automations.removeAll { $0.id == id }
    }

    /// Called every second. A run is skipped while the last one is still busy, so slow ones don't pile up.
    func runDueAutomations() {
        let now = Date()
        for automation in automations {
            guard let due = automation.nextRun, due <= now else { continue }
            updateAutomation(automation.id) { $0.nextRun = $0.nextRun(after: now) }
            if session(automation.lastSessionID)?.isBusy == true {
                updateAutomation(automation.id) { $0.lastError = "Skipped a run: the last one was still busy." }
            } else {
                run(automation)
            }
        }
    }

    /// Starts the automation's session in the background, in a sidebar group named after it.
    func run(_ automation: Automation) {
        let started = Date()
        // "nightly-review-20261018-0900"
        let time = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: started)
        let stamp = String(format: "%04d%02d%02d-%02d%02d", time.year ?? 0, time.month ?? 0, time.day ?? 0,
                           time.hour ?? 0, time.minute ?? 0)
        let slug = Git.branchName(for: automation.name) // empty for a name like "🌙"; a branch can't start with "-"
        let branch = automation.newWorktree ? (slug.isEmpty ? "automation" : slug) + "-" + stamp : nil
        Task {
            do {
                let session = try await startSession(folder: automation.folder, agentID: automation.agentID,
                                                     prompt: automation.prompt, name: automation.name.isEmpty ? nil : automation.name,
                                                     branch: branch, base: nil,
                                                     claudeArgs: ClaudeCode.arguments(model: automation.model, effort: automation.effort))
                // The group has the automation's id, so later runs find it again after the user renames it.
                if !groups.contains(where: { $0.id == automation.id }) {
                    groups.append(SessionGroup(id: automation.id, name: automation.title))
                }
                move([session.id], to: automation.id)
                updateAutomation(automation.id) {
                    $0.lastRun = started
                    $0.lastSessionID = session.id
                    $0.lastError = nil
                }
            } catch {
                updateAutomation(automation.id) {
                    $0.lastRun = started
                    $0.lastError = (error as? ToolError)?.message ?? "\(error)"
                }
            }
        }
    }

    private func updateAutomation(_ id: UUID, _ change: (inout Automation) -> Void) {
        guard let index = automations.firstIndex(where: { $0.id == id }) else { return }
        change(&automations[index])
    }
}
