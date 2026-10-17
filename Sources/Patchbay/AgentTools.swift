import Foundation

/// Patchbay's MCP tools for the agents in its terminals (served by `ControlServer`): a lead agent can start other
/// agents, give them tasks and follow them, while the user sees and controls them all in the sidebar. Any session
/// can be read; only the sessions an agent started can be typed into or closed.
enum AgentTool: String, CaseIterable {
    case listSessions = "list_sessions"
    case readOutput = "read_output"
    case newSession = "new_session"
    case sendInput = "send_input"
    case waitFor = "wait_for"
    case closeSession = "close_session"

    static let instructions = """
        Patchbay is the terminal app you run in. Its sidebar lists sessions: terminals, often with a coding agent \
        such as Claude Code or Codex in them. These tools let you see them and start and direct agents of your own, \
        which the user sees next to you. Use them when the user wants work split across agents: start each agent \
        with new_session (with a branch, so it works in its own git worktree), wait_for it, read_output to see what \
        it did, send_input to follow up. You can type into and close only the sessions you started. When one asks \
        for permission, leave that to the user.
        """

    var description: String {
        switch self {
        case .listSessions: "Lists Patchbay's sessions with their id, agent, status, folder and git branch."
        case .readOutput: "Returns the last lines of a session's terminal, scrollback included, as plain text."
        case .newSession: """
            Opens a session in Patchbay running an agent and returns it. With a branch, the session gets its own \
            git worktree on that branch (an existing branch is checked out, a new one starts at base).
            """
        case .sendInput: """
            Types text into a session you started, as one paste, and presses Return unless submit is false. Not \
            while it asks for permission.
            """
        case .waitFor: """
            Waits until a session stops working: its agent finished its turn or needs input, or its shell is back \
            at the prompt. Returns the session; its status says which, or that it is still working after the timeout.
            """
        case .closeSession: "Closes a session you started. Its worktree, if any, is kept."
        }
    }

    private var parameters: [String: [String: Any]] {
        let session = ["type": "string", "description": "The session's id from list_sessions"]
        return switch self {
        case .listSessions: [:]
        case .readOutput: ["session": session, "lines": ["type": "integer", "description": "How many (default 100)"]]
        case .newSession: [
            "folder": ["type": "string", "description": "Absolute path; default your own folder"],
            "agent": ["type": "string", "enum": Agent.all.map(\.id) + ["shell"], "description": "Default claude"],
            "prompt": ["type": "string", "description": "The agent's first task"],
            "name": ["type": "string", "description": "Shown in the sidebar"],
            "branch": ["type": "string"],
            "base": ["type": "string", "description": "Branch a new branch starts at; default the folder's current one"],
        ]
        case .sendInput: ["session": session, "text": ["type": "string"], "submit": ["type": "boolean"]]
        case .waitFor: ["session": session, "timeout": ["type": "integer", "description": "Seconds (default 300)"]]
        case .closeSession: ["session": session]
        }
    }

    private var required: [String] {
        switch self {
        case .listSessions, .newSession: []
        case .readOutput, .waitFor, .closeSession: ["session"]
        case .sendInput: ["session", "text"]
        }
    }

    var schema: [String: Any] {
        ["name": rawValue, "description": description,
         "inputSchema": ["type": "object", "properties": parameters, "required": required]]
    }
}

private struct ToolError: Error {
    let message: String
}

extension SessionStore {
    /// Answers one JSON-RPC message from an agent's MCP server; nil for notifications, which get no reply.
    func handleMCP(_ line: Data, caller: UUID?) async -> Data? {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = request["id"]
        else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch request["method"] as? String {
        case "initialize":
            reply["result"] = ["protocolVersion": params["protocolVersion"] ?? "2025-06-18",
                               "capabilities": ["tools": [String: Any]()],
                               "serverInfo": ["name": "patchbay", "version": "1.0"],
                               "instructions": AgentTool.instructions]
        case "tools/list":
            reply["result"] = ["tools": AgentTool.allCases.map(\.schema)]
        case "tools/call":
            let content: String
            var isError = false
            do {
                let name = params["name"] as? String ?? ""
                guard let tool = AgentTool(rawValue: name) else { throw ToolError(message: "Unknown tool \(name)") }
                content = try await call(tool, params["arguments"] as? [String: Any] ?? [:], caller: caller)
            } catch {
                content = (error as? ToolError)?.message ?? "\(error)"
                isError = true
            }
            reply["result"] = ["content": [["type": "text", "text": content]], "isError": isError]
        case "ping":
            reply["result"] = [String: Any]()
        default:
            reply["error"] = ["code": -32601, "message": "Method not found"]
        }
        return try? JSONSerialization.data(withJSONObject: reply)
    }

    private func call(_ tool: AgentTool, _ args: [String: Any], caller: UUID?) async throws -> String {
        switch tool {
        case .listSessions:
            return try json(sessions.map { describe($0, caller: caller) })
        case .readOutput:
            let session = try find(args)
            let text = String(decoding: session.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            while lines.last?.isEmpty == true { lines.removeLast() }
            return lines.suffix(args["lines"] as? Int ?? 100).joined(separator: "\n")
        case .newSession:
            return try json(describe(try await startSession(args, caller: caller), caller: caller))
        case .sendInput:
            let session = try find(args, startedBy: caller)
            guard !session.asksApproval else { throw ToolError(message: "It asks for permission; that's for the user to answer.") }
            let text = args["text"] as? String ?? ""
            if args["submit"] as? Bool ?? true { session.submit(text) } else { session.paste(text) }
            return "Sent."
        case .waitFor:
            let id = try find(args).id
            let deadline = Date().addingTimeInterval(TimeInterval(args["timeout"] as? Int ?? 300))
            while let session = session(id), session.isWorking, Date() < deadline {
                try await Task.sleep(for: .milliseconds(250))
            }
            guard let session = session(id) else { return "The session was closed." }
            return try json(describe(session, caller: caller))
        case .closeSession:
            close(try find(args, startedBy: caller))
            return "Closed."
        }
    }

    private func startSession(_ args: [String: Any], caller: UUID?) async throws -> TerminalSession {
        let lead = session(caller)
        var folder = args["folder"] as? String ?? lead?.cwd ?? NSHomeDirectory()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError(message: "No folder at \(folder)")
        }
        let agentID = args["agent"] as? String ?? Agent.claude.id
        let agent = Agent.named(agentID)
        guard agent != nil || agentID == "shell" else { throw ToolError(message: "Unknown agent \(agentID)") }
        let prompt = args["prompt"] as? String
        if prompt != nil, agent?.promptStyle ?? .unsupported == .unsupported {
            throw ToolError(message: "\(agent?.name ?? "A shell") takes no first prompt; use send_input once it runs.")
        }
        var setup: String?
        if let branch = args["branch"] as? String {
            let start = folder
            guard let repo = await inBackground({ Git.repository(at: start) }) else {
                throw ToolError(message: "\(folder) isn't in a git repository")
            }
            let base = repo.branches.contains(branch) ? nil : args["base"] as? String ?? repo.current
            if let error = await inBackground({ repo.addWorktree(branch: branch, base: base) }) {
                throw ToolError(message: error)
            }
            folder = repo.worktreePath(for: branch)
            setup = repo.setup?.setup
        }
        let session = newSession(directory: folder, name: args["name"] as? String, agent: agent, prompt: prompt,
                                 setup: setup, select: false)
        // The lead's group shows who started it; a lead without one gets a group named after it.
        if let lead {
            session.startedBy = lead.id
            let group = lead.groupID ?? {
                let group = SessionGroup(name: lead.displayName)
                groups.append(group)
                return group.id
            }()
            move(lead.groupID == nil ? [lead.id, session.id] : [session.id], to: group)
        }
        return session
    }

    private func find(_ args: [String: Any]) throws -> TerminalSession {
        let id = args["session"] as? String ?? ""
        guard let session = sessions.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw ToolError(message: "No session \(id); see list_sessions.")
        }
        return session
    }

    private func find(_ args: [String: Any], startedBy caller: UUID?) throws -> TerminalSession {
        let session = try find(args)
        guard caller != nil, session.startedBy == caller else {
            throw ToolError(message: "\(session.displayName) wasn't started by you; only the user can do that there.")
        }
        return session
    }

    private func describe(_ session: TerminalSession, caller: UUID?) -> [String: Any] {
        [
            "id": session.id.uuidString, "name": session.displayName, "agent": session.agent?.name,
            "status": session.statusLabel, "detail": session.detailLine, "folder": session.cwd,
            "branch": session.git?.branch, "you": session.id == caller ? true : nil,
            "started_by_you": caller != nil && session.startedBy == caller ? true : nil,
        ].compactMapValues { $0 }
    }

    private func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               as: UTF8.self)
    }
}
