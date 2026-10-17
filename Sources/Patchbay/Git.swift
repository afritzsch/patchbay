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

    /// Runs git and returns its output, or nil when it fails or takes longer than 2 s.
    /// `--no-optional-locks`: a plain `git status` takes index.lock, which would make an agent's own `git commit` fail.
    private static func run(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-C", directory] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
