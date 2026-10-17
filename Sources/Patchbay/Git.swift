import Foundation

struct GitInfo: Equatable {
    /// The branch, or a short hash when HEAD is detached.
    var branch: String
    var ahead: Int
    var behind: Int
    /// Top of the working tree.
    var root: String
    /// Staged, unstaged and untracked files.
    var changes: [GitChange]
    var changed: Int { changes.count }
}

/// One line of `git status`: the status letters of the index and of the working tree (" " for none, "?" untracked).
struct GitChange: Identifiable, Equatable {
    var index: Character
    var worktree: Character
    var path: String
    var id: String { path }
    var isStaged: Bool { !" ?U".contains(index) }
    var isUnstaged: Bool { worktree != " " }
}

/// A row selected in the source control tab. A file can be in both the staged and the unstaged list.
struct ChangeSelection: Hashable {
    var path: String
    var staged: Bool
    var untracked: Bool
}

/// One line of a file diff, with its line numbers in the old and new file.
struct DiffLine: Identifiable, Equatable {
    enum Kind { case hunk, context, added, removed, note }
    var id: Int
    var kind: Kind
    var old: Int?
    var new: Int?
    var text: String
}

enum Git {
    /// nil when `directory` isn't in a git repository. Blocking: call off the main thread.
    static func info(at directory: String) -> GitInfo? {
        guard let root = run(["rev-parse", "--show-toplevel"], in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let status = run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: directory)
        else { return nil }
        return parse(status: status, root: root)
    }

    /// Reads `git status --porcelain=v2 --branch -z`: `# branch.*` headers, then an entry per changed file, whose
    /// path is its last field. A renamed or copied file's entry (type 2) is followed by its old path.
    static func parse(status: String, root: String) -> GitInfo {
        var info = GitInfo(branch: "", ahead: 0, behind: 0, root: root, changes: [])
        var oid = ""
        let fieldCounts: [Character: Int] = ["1": 9, "2": 10, "u": 11]
        var entries = status.split(separator: "\0")[...]
        while let entry = entries.popFirst() {
            if entry.hasPrefix("# branch.head ") {
                info.branch = String(entry.dropFirst("# branch.head ".count))
            } else if entry.hasPrefix("# branch.oid ") {
                oid = String(entry.dropFirst("# branch.oid ".count))
            } else if entry.hasPrefix("# branch.ab ") { // "# branch.ab +1 -0", absent without an upstream
                let fields = entry.split(separator: " ")
                guard fields.count == 4 else { continue }
                info.ahead = Int(fields[2].dropFirst()) ?? 0
                info.behind = Int(fields[3].dropFirst()) ?? 0
            } else if entry.hasPrefix("? ") {
                info.changes.append(GitChange(index: "?", worktree: "?", path: String(entry.dropFirst(2))))
            } else if let type = entry.first, let count = fieldCounts[type] {
                if type == "2" { _ = entries.popFirst() }
                // "1 .M N... 100644 100644 100644 <hash> <hash> path"; "." is an unchanged side.
                let fields = entry.split(separator: " ", maxSplits: count - 1, omittingEmptySubsequences: false)
                guard fields.count == count, fields[1].count == 2 else { continue }
                let xy = fields[1].map { $0 == "." ? " " : $0 }
                info.changes.append(GitChange(index: xy[0], worktree: xy[1], path: String(fields[count - 1])))
            }
        }
        if info.branch == "(detached)" { info.branch = String(oid.prefix(7)) }
        return info
    }

    /// The diff of one file, from either the staged or the unstaged side. nil when git fails.
    static func diff(of selection: ChangeSelection, in root: String) -> String? {
        // Plain output whatever the user's config says (external diff tools, color.ui = always).
        let diff = ["diff", "--no-ext-diff", "--no-color"]
        let arguments = selection.untracked ? diff + ["--no-index", "--", "/dev/null", selection.path]
            : diff + (selection.staged ? ["--cached"] : []) + ["--", selection.path]
        // --no-index exits with 1 when the files differ.
        guard let (status, output) = execute(arguments, in: root, timeout: 5, mergeErrors: false), status <= 1 else { return nil }
        return output
    }

    /// Reads `git diff` output for one file: skips the `diff --git` header and numbers the lines of each hunk.
    /// Output without hunks (binary files, mode changes) comes back as notes.
    static func parseDiff(_ diff: String) -> [DiffLine] {
        // Not split(separator: "\n"): a String keeps "\r\n" as one Character, so CRLF files wouldn't split.
        let all = diff.split(whereSeparator: \.isNewline)
        guard let start = all.firstIndex(where: { $0.hasPrefix("@@") }) else {
            return all.enumerated().map { DiffLine(id: $0, kind: .note, text: String($1)) }
        }
        var lines: [DiffLine] = []
        var (old, new) = (0, 0)
        for raw in all[start...] {
            var line = DiffLine(id: lines.count, kind: .context, old: old, new: new, text: String(raw.dropFirst()))
            switch raw.first {
            case "@": // "@@ -12,7 +12,9 @@ section"
                let ranges = raw.split(separator: " ").dropFirst().prefix(2).compactMap { Int($0.dropFirst().split(separator: ",")[0]) }
                guard ranges.count == 2 else { continue }
                (old, new) = (ranges[0], ranges[1])
                line = DiffLine(id: line.id, kind: .hunk, text: String(raw))
            case "+": line.kind = .added; line.old = nil; new += 1
            case "-": line.kind = .removed; line.new = nil; old += 1
            case "\\": line = DiffLine(id: line.id, kind: .note, text: String(raw.dropFirst(2)))
            default: old += 1; new += 1
            }
            lines.append(line)
        }
        return lines
    }

    // The actions below change the repository and return git's error message, or nil on success.
    // Blocking: call off the main thread.

    /// Pass `["."]` for everything.
    static func stage(_ paths: [String], in root: String) -> String? {
        perform(["add", "-A", "--"] + paths, in: root)
    }

    static func unstage(_ paths: [String], in root: String) -> String? {
        perform(["reset", "-q", "--"] + paths, in: root)
    }

    /// Throws away the working tree version: restores a tracked file, deletes an untracked one.
    static func discard(_ change: GitChange, in root: String) -> String? {
        perform(change.worktree == "?" ? ["clean", "-f", "--", change.path] : ["restore", "--", change.path], in: root)
    }

    static func commit(_ message: String, in root: String) -> String? {
        perform(["commit", "-m", message], in: root, timeout: 60)
    }

    private static func perform(_ arguments: [String], in directory: String, timeout: TimeInterval = 10) -> String? {
        guard let (status, output) = execute(arguments, in: directory, timeout: timeout, mergeErrors: true) else {
            return "Couldn't run git."
        }
        return status == 0 ? nil : output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs git and returns its output, or nil when it fails or takes longer than 2 s.
    private static func run(_ arguments: [String], in directory: String) -> String? {
        guard let (status, output) = execute(arguments, in: directory, timeout: 2, mergeErrors: false) else { return nil }
        return status == 0 ? output : nil
    }

    /// `--no-optional-locks`: a plain `git status` takes index.lock, which would make an agent's own `git commit` fail.
    private static func execute(_ arguments: [String], in directory: String, timeout: TimeInterval, mergeErrors: Bool)
        -> (status: Int32, output: String)? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-C", directory] + arguments
        process.standardOutput = pipe
        process.standardError = mergeErrors ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let kill = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: kill)
        // Read on another thread: children of git (hooks) can keep the pipe open after git has exited or been
        // killed, and reading to the end would wait for them too.
        nonisolated(unsafe) var data = Data()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        process.waitUntilExit()
        kill.cancel()
        guard read.wait(timeout: .now() + 1) == .success else { return (process.terminationStatus, "") }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Runs blocking work (a process, a directory scan) on a GCD thread and awaits it. Swift concurrency has only
/// about one thread per core for all tasks, so they must never sit waiting for a process.
func inBackground<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: work()) }
    }
}
