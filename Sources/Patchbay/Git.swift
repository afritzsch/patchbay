import Foundation

struct GitInfo: Equatable {
    /// The branch, or a short hash when HEAD is detached.
    var branch: String
    /// Staged, unstaged and untracked files.
    var changed: Int
    var ahead: Int
    var behind: Int
    /// Top of the working tree.
    var root: String
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

enum Git {
    /// nil when `directory` isn't in a git repository. Blocking: call off the main thread.
    static func info(at directory: String) -> GitInfo? {
        guard let root = run(["rev-parse", "--show-toplevel"], in: directory)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let status = run(["status", "--porcelain=v2", "--branch"], in: directory) else { return nil }
        return parse(status: status, root: root)
    }

    /// Reads `git status --porcelain=v2 --branch`: `# branch.*` header lines, then one line per changed file.
    static func parse(status: String, root: String) -> GitInfo {
        var info = GitInfo(branch: "", changed: 0, ahead: 0, behind: 0, root: root)
        var oid = ""
        for line in status.split(separator: "\n") {
            if !line.hasPrefix("#") {
                info.changed += 1
            } else if line.hasPrefix("# branch.head ") {
                info.branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.oid ") {
                oid = String(line.dropFirst("# branch.oid ".count))
            } else if line.hasPrefix("# branch.ab ") { // "# branch.ab +1 -0", absent without an upstream
                let fields = line.split(separator: " ")
                guard fields.count == 4 else { continue }
                info.ahead = Int(fields[2].dropFirst()) ?? 0
                info.behind = Int(fields[3].dropFirst()) ?? 0
            }
        }
        if info.branch == "(detached)" { info.branch = String(oid.prefix(7)) }
        return info
    }

    /// Changed files, for the source control tab. nil when git fails.
    static func changes(at root: String) -> [GitChange]? {
        run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root).map(parseChanges)
    }

    /// Reads `git status --porcelain=v1 -z`: `XY path` entries, a renamed file is followed by its old path.
    static func parseChanges(_ status: String) -> [GitChange] {
        var entries = status.split(separator: "\0")[...]
        var changes: [GitChange] = []
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let (index, worktree) = (entry.first!, entry[entry.index(after: entry.startIndex)])
            if "RC".contains(index) || "RC".contains(worktree) { _ = entries.popFirst() }
            changes.append(GitChange(index: index, worktree: worktree, path: String(entry.dropFirst(3))))
        }
        return changes
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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        kill.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
