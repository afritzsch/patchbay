import SwiftUI

/// One plan limit window as Claude Code reports it to the status line.
struct UsageWindow: Equatable {
    let usedPercent: Double
    let resetsAt: Date
}

/// Claude plan usage (5-hour and weekly limits), read from the `usage.json` the status line script writes
/// every time a Claude session updates its status line. Only as fresh as the last update from any session;
/// the store reloads it every few seconds.
@MainActor @Observable
final class UsageMonitor {
    private(set) var fiveHour: UsageWindow?
    private(set) var sevenDay: UsageWindow?
    private(set) var updatedAt: Date?

    static let file = ShellIntegration.supportDir.appendingPathComponent("usage.json")
    @ObservationIgnored private var lastModified: Date?

    init() {
        reload()
    }

    func reload() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: Self.file.path),
              let modified = attributes[.modificationDate] as? Date, modified != lastModified,
              let data = try? Data(contentsOf: Self.file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lastModified = modified
        updatedAt = modified
        fiveHour = Self.window(json["five_hour"])
        sevenDay = Self.window(json["seven_day"])
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any],
              let used = (dict["used_percentage"] as? NSNumber)?.doubleValue,
              let resets = (dict["resets_at"] as? NSNumber)?.doubleValue else { return nil }
        return UsageWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
    }
}

/// Progress bars for the 5-hour and weekly limits, at the bottom of the sidebar.
struct UsageBars: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        let usage = store.usage
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 7) {
                if usage.fiveHour != nil || usage.sevenDay != nil {
                    UsageBar(title: "5-hour", window: usage.fiveHour, now: context.date, weekly: false)
                    UsageBar(title: "Weekly", window: usage.sevenDay, now: context.date, weekly: true)
                    if let updated = usage.updatedAt {
                        Text("Updated \(updated, format: .relative(presentation: .named))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .help("Claude plan usage, as reported to the status line of your Claude sessions")
    }
}

private struct UsageBar: View {
    let title: String
    let window: UsageWindow?
    let now: Date
    let weekly: Bool

    var body: some View {
        // Once the window has reset, the old number no longer applies.
        let isReset = window.map { $0.resetsAt <= now } ?? false
        let percent = isReset ? 0 : min(max(window?.usedPercent ?? 0, 0), 100)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(.medium))
                Spacer(minLength: 4)
                if let window {
                    Text(isReset ? "reset" : "\(Int(percent.rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(color(percent))
                    if !isReset {
                        Text("· resets \(resetText(window.resetsAt))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("no data").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            // Drawn by hand: the system progress bar ignores tint colors on macOS.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(color(percent))
                        .frame(width: geometry.size.width * percent / 100)
                }
            }
            .frame(height: 5)
            .accessibilityElement()
            .accessibilityLabel("\(title) usage")
            .accessibilityValue("\(Int(percent.rounded())) percent")
        }
    }

    private func color(_ percent: Double) -> Color {
        percent >= 90 ? .red : percent >= 70 ? .orange : .green
    }

    private func resetText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
