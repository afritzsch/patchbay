import AppKit

/// An interactive Claude Code session running in another terminal app (Terminal, iTerm, …).
struct ExternalSession: Identifiable, Equatable {
    let pid: pid_t
    let sessionID: String
    let cwd: String
    let busy: Bool
    /// The app whose window it runs in, if it could be found.
    let hostApp: String?
    /// Command-line options worth keeping when the session is resumed in this app.
    let carriedArgs: [String]

    var id: pid_t { pid }
    var displayName: String { (cwd as NSString).lastPathComponent }

    var hasTranscript: Bool { ClaudeTranscripts.exist(for: sessionID) }
}

/// Finds Claude Code sessions outside this app through the registry Claude keeps in `~/.claude/sessions`,
/// one `<pid>.json` per running session.
enum ExternalSessionScanner {
    // The dev test copy (DevHooks.swift) gets its own, so it can't list or end the user's real sessions.
    static let registry = ProcessInfo.processInfo.environment["PATCHBAY_DEV_DIR"]
        .map { URL(fileURLWithPath: $0).appendingPathComponent("claude-sessions") }
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")

    static func scan() -> [ExternalSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil)) ?? []
        let ownPID = getpid()
        var found: [ExternalSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value,
                  let sessionID = json["sessionId"] as? String,
                  let cwd = json["cwd"] as? String,
                  (json["kind"] as? String ?? "interactive") == "interactive",
                  (json["entrypoint"] as? String ?? "cli") == "cli" // not SDK/headless runs by other tools
            else { continue }
            // Stale entries, reused PIDs and our own sessions are skipped.
            var argv = arguments(of: pid)
            // Installed through npm, Claude runs as `node /path/to/claude …`.
            if argv.count > 1, let first = argv.first, ["node", "bun"].contains((first as NSString).lastPathComponent) {
                argv.removeFirst()
            }
            guard kill(pid, 0) == 0, let executable = argv.first,
                  (executable as NSString).lastPathComponent.hasPrefix("claude") || executable.contains("/claude"),
                  !argv.contains("-p"), !argv.contains("--print"),
                  !ancestors(of: pid).contains(ownPID)
            else { continue }
            found.append(ExternalSession(
                pid: pid,
                sessionID: sessionID,
                cwd: cwd,
                busy: (json["status"] as? String) == "busy",
                hostApp: hostApp(of: pid),
                carriedArgs: carriedArgs(from: Array(argv.dropFirst()))
            ))
        }
        return found.sorted { $0.pid < $1.pid }
    }

    /// Ends the external session so its conversation can be resumed here: SIGTERM lets Claude save and
    /// restore the terminal; SIGKILL follows if it hasn't exited after a few seconds.
    @MainActor
    static func terminate(_ session: ExternalSession, completion: @escaping @MainActor (_ ended: Bool) -> Void) {
        kill(session.pid, SIGTERM)
        let killAt = Date().addingTimeInterval(4)
        let deadline = Date().addingTimeInterval(8)
        func check() {
            let alive = kill(session.pid, 0) == 0
            if alive && Date() > killAt { kill(session.pid, SIGKILL) }
            if !alive || Date() > deadline {
                completion(!alive)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
            }
        }
        check()
    }

    // MARK: - Processes

    static func carriedArgs(from args: [String]) -> [String] {
        var kept: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
            if ClaudeCode.carriedFlagOptions.contains(arg) {
                kept.append(arg)
            } else if ClaudeCode.carriedValueOptions.contains(name) {
                if arg.contains("=") {
                    kept.append(arg)
                } else if index + 1 < args.count {
                    kept += [arg, args[index + 1]]
                    index += 1
                }
            }
            index += 1
        }
        return kept
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    private static func ancestors(of pid: pid_t) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        while let next = parent(of: current), next > 1, chain.count < 32 {
            chain.append(next)
            current = next
        }
        return chain
    }

    private static func hostApp(of pid: pid_t) -> String? {
        for ancestor in ancestors(of: pid) {
            if let app = NSRunningApplication(processIdentifier: ancestor), app.activationPolicy == .regular {
                return app.localizedName
            }
        }
        return nil
    }

    /// The process's argv, via KERN_PROCARGS2 (exact, unlike `ps` output).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var offset = MemoryLayout<Int32>.size
        // Skip the executable path and the padding after it.
        while offset < size, buffer[offset] != 0 { offset += 1 }
        while offset < size, buffer[offset] == 0 { offset += 1 }
        var args: [String] = []
        while args.count < argc, offset < size {
            let start = offset
            while offset < size, buffer[offset] != 0 { offset += 1 }
            args.append(String(decoding: buffer[start..<offset], as: UTF8.self))
            offset += 1
        }
        return args
    }
}
