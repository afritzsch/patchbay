import Foundation

enum HistoryKind: String, Codable {
    case sessionOpened, sessionClosed, movedIn
    case prompt, claudeFinished, claudeNeedsInput
    case command

    /// The filter group shown in the history view.
    var group: HistoryGroup {
        switch self {
        case .prompt: .prompts
        case .claudeFinished, .claudeNeedsInput: .claude
        case .command: .commands
        case .sessionOpened, .sessionClosed, .movedIn: .sessions
        }
    }
}

enum HistoryGroup: String, CaseIterable, Identifiable {
    case prompts = "Prompts"
    case claude = "Claude"
    case commands = "Commands"
    case sessions = "Sessions"

    var id: String { rawValue }
}

/// One thing that happened in a session. Name and folder are recorded as they were at the time, so the
/// entry still reads right after the session is renamed or closed.
struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    let kind: HistoryKind
    let sessionID: UUID
    let sessionName: String
    let directory: String
    /// The prompt, command, Claude's question, or a description.
    let text: String
    var claudeSessionID: String?
    var exitCode: Int?
    /// Seconds a command or Claude's turn took.
    var duration: Double?
}

/// The activity history, kept as JSON lines in Application Support and appended to as things happen.
@MainActor @Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []

    nonisolated static let file = ShellIntegration.supportDir.appendingPathComponent("history.jsonl")
    static let maxEntries = 20_000
    /// Writes to the file, in order and off the main thread.
    private static let disk = DispatchQueue(label: "app.patchbay.history")

    /// 0 keeps everything.
    var retentionDays = UserDefaults.standard.integer(forKey: Preferences.Keys.historyRetentionDays) {
        didSet {
            UserDefaults.standard.set(retentionDays, forKey: Preferences.Keys.historyRetentionDays)
            prune()
        }
    }

    init() {
        load()
    }

    func record(_ entry: HistoryEntry) {
        entries.append(entry)
        Self.disk.async {
            let fm = FileManager.default
            if !fm.fileExists(atPath: Self.file.path) { fm.createFile(atPath: Self.file.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: Self.file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Self.lines([entry]))
        }
        if entries.count > Self.maxEntries + 1000 { prune() }
    }

    func clear() {
        entries = []
        Self.disk.async { try? FileManager.default.removeItem(at: Self.file) }
    }

    /// Waits for pending writes, before the app quits.
    func flush() {
        Self.disk.sync {}
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }
        entries = data.split(separator: UInt8(ascii: "\n")).compactMap { try? Self.decoder.decode(HistoryEntry.self, from: $0) }
        prune()
    }

    /// Drops entries past the retention period or the size cap, and rewrites the file if anything went.
    private func prune() {
        var kept = entries
        if retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
            kept.removeAll { $0.date < cutoff }
        }
        if kept.count > Self.maxEntries { kept.removeFirst(kept.count - Self.maxEntries) }
        guard kept.count != entries.count else { return }
        entries = kept
        Self.disk.async { [kept] in try? Self.lines(kept).write(to: Self.file, options: .atomic) }
    }

    private nonisolated static func lines(_ entries: [HistoryEntry]) -> Data {
        var data = Data()
        for entry in entries {
            if let line = try? encoder.encode(entry) { data += line + Data("\n".utf8) }
        }
        return data
    }

    private nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
