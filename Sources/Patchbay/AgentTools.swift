import AppKit

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
    case createAutomation = "create_automation"
    case listAutomations = "list_automations"
    case deleteAutomation = "delete_automation"

    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    static let instructions = """
        Patchbay is the terminal app you run in. Its sidebar lists sessions: terminals, often with a coding agent \
        such as Claude Code or Codex in them. These tools let you see them and start and direct agents of your own, \
        which the user sees next to you. Use them when the user wants work split across agents: start each agent \
        with new_session (with a branch, so it works in its own git worktree), wait_for it, read_output to see what \
        it did, send_input to follow up. You can type into and close only the sessions you started. When one asks \
        for permission, leave that to the user. For work the user wants done regularly, such as a daily review, \
        create_automation has Patchbay start a session on a schedule; list_automations and delete_automation \
        manage them.
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
        case .createAutomation: """
            Schedules a session that Patchbay starts regularly, as new_session would: an agent with a prompt, or a \
            shell running a command, optionally in a new git worktree for each run. It runs only while Patchbay is \
            open; a run missed while it was closed starts once it's back. The user sees, edits and deletes it in the \
            sidebar's Automations tab. Returns it with its next run.
            """
        case .listAutomations: "Lists Patchbay's automations with their id, prompt, schedule, next and last run, and last error."
        case .deleteAutomation: "Deletes an automation. The sessions it already started keep running."
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
            "prompt": ["type": "string", "description": "The agent's first task, or a command for a shell"],
            "name": ["type": "string", "description": "Shown in the sidebar"],
            "branch": ["type": "string"],
            "base": ["type": "string", "description": "Branch a new branch starts at; default main (or master), else the folder's current one"],
        ]
        case .sendInput: ["session": session, "text": ["type": "string"], "submit": ["type": "boolean"]]
        case .waitFor: ["session": session, "timeout": ["type": "integer", "description": "Seconds (default 300)"]]
        case .closeSession: ["session": session]
        case .listAutomations: [:]
        case .deleteAutomation: ["automation": ["type": "string", "description": "The automation's id from list_automations"]]
        case .createAutomation: [
            "folder": ["type": "string", "description": "Absolute path; default your own folder"],
            "agent": ["type": "string", "enum": Agent.all.map(\.id) + ["shell"], "description": "Default claude"],
            "prompt": ["type": "string", "description": "The agent's task each run, or a command for a shell"],
            "name": ["type": "string", "description": "Shown in the sidebar"],
            "repeat": ["type": "string", "enum": Automation.Frequency.allCases.map(\.rawValue)],
            "time": ["type": "string", "description": "HH:MM, 24-hour, local time (default 09:00); hourly uses only the minutes"],
            "weekday": ["type": "string", "enum": Self.weekdays, "description": "For weekly (default monday)"],
            "new_worktree": ["type": "boolean", "description": "Each run in its own new worktree (default false)"],
        ]
        }
    }

    private var required: [String] {
        switch self {
        case .listSessions, .newSession, .listAutomations: []
        case .readOutput, .waitFor, .closeSession: ["session"]
        case .sendInput: ["session", "text"]
        case .createAutomation: ["prompt", "repeat"]
        case .deleteAutomation: ["automation"]
        }
    }

    var schema: [String: Any] {
        ["name": rawValue, "description": description,
         "inputSchema": ["type": "object", "properties": parameters, "required": required]]
    }
}

struct ToolError: Error {
    let message: String
}

/// `patchbay/open` from another app on the Mac: a Claude session in `folder` that resumes a conversation, starts
/// with a prompt, or neither.
struct OpenRequest {
    let folder: String
    let resume: String?
    let prompt: String?
    let name: String?

    init(_ params: [String: Any]) throws {
        guard let folder = params["folder"] as? String else { throw ToolError(message: "folder is required") }
        resume = params["resume"] as? String
        prompt = params["prompt"] as? String
        name = params["name"] as? String
        guard resume == nil || prompt == nil else { throw ToolError(message: "Pass resume or prompt, not both") }
        _ = try SessionStore.checkStart(folder: folder, agentID: Agent.claude.id, prompt: prompt)
        self.folder = folder
    }
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
        case "patchbay/open": // From other apps, not an agent tool.
            do {
                reply["result"] = ["session": try open(OpenRequest(params)).id.uuidString]
            } catch {
                reply["error"] = ["code": -32602, "message": (error as? ToolError)?.message ?? "\(error)"]
            }
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
        case .createAutomation:
            return try json(describe(try await createAutomation(args, caller: caller)))
        case .listAutomations:
            return try json(automations.map(describe))
        case .deleteAutomation:
            let id = args["automation"] as? String ?? ""
            guard let automation = automations.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
                throw ToolError(message: "No automation \(id); see list_automations.")
            }
            deleteAutomation(automation.id)
            return "Deleted."
        }
    }

    /// Opens the session another app asked for, focused and in front. A conversation already open here is focused.
    private func open(_ request: OpenRequest) throws -> TerminalSession {
        let open = request.resume.flatMap { id in sessions.first { $0.isClaude && $0.claudeSessionID == id } }
        if let id = request.resume, open == nil {
            guard !isRunning(claudeConversation: id) else { throw ToolError(message: "\(id) is open in another terminal") }
            guard ClaudeTranscripts.exist(for: id) else { throw ToolError(message: "No Claude conversation \(id)") }
        }
        let session = open ?? newSession(directory: request.folder, name: request.name, agent: .claude,
                                         prompt: request.prompt, resumeClaudeID: request.resume)
        show(session.id)
        NSApp.activate()
        AppDelegate.shared?.mainWindow?.makeKeyAndOrderFront(nil)
        return session
    }

    private func startSession(_ args: [String: Any], caller: UUID?) async throws -> TerminalSession {
        let lead = session(caller)
        let session = try await startSession(folder: args["folder"] as? String ?? lead?.cwd ?? NSHomeDirectory(),
                                             agentID: args["agent"] as? String ?? Agent.claude.id,
                                             prompt: args["prompt"] as? String, name: args["name"] as? String,
                                             branch: args["branch"] as? String, base: args["base"] as? String)
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

    /// Opens a session in the background running `agentID` ("shell" for none) with a first prompt, which a shell
    /// runs as a command. With a branch, it gets its own git worktree on it (an existing branch is checked out,
    /// a new one starts at `base`, default `repo.defaultBase`). Used by `new_session` and automations.
    func startSession(folder: String, agentID: String, prompt: String?, name: String?, branch: String?,
                      base: String?) async throws -> TerminalSession {
        let agent = try Self.checkStart(folder: folder, agentID: agentID, prompt: prompt)
        var folder = folder
        var commands: [String] = []
        if let branch {
            let start = folder
            guard let repo = await inBackground({ Git.repository(at: start) }) else {
                throw ToolError(message: "\(folder) isn't in a git repository")
            }
            let base = repo.branches.contains(branch) ? nil : base ?? repo.defaultBase
            if let error = await inBackground({ repo.addWorktree(branch: branch, base: base) }) {
                throw ToolError(message: error)
            }
            folder = repo.worktreePath(for: branch)
            commands += [repo.setup?.setup].compactMap { $0 }
        }
        if agent == nil, let prompt { commands.append(prompt) }
        return newSession(directory: folder, name: name, agent: agent, prompt: prompt,
                          setup: commands.isEmpty ? nil : commands.joined(separator: " && "), select: false)
    }

    /// The agent `agentID` names (nil for a shell), if it can be started in `folder` with `prompt`.
    nonisolated static func checkStart(folder: String, agentID: String, prompt: String?) throws -> Agent? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError(message: "No folder at \(folder)")
        }
        let agent = Agent.named(agentID)
        guard agent != nil || agentID == "shell" else { throw ToolError(message: "Unknown agent \(agentID)") }
        if prompt != nil, let agent, agent.promptStyle == .unsupported {
            throw ToolError(message: "\(agent.name) takes no first prompt; use send_input once it runs.")
        }
        return agent
    }

    private func createAutomation(_ args: [String: Any], caller: UUID?) async throws -> Automation {
        var automation = Automation(name: args["name"] as? String ?? "",
                                    folder: args["folder"] as? String ?? session(caller)?.cwd ?? NSHomeDirectory(),
                                    agentID: args["agent"] as? String ?? Agent.claude.id,
                                    prompt: args["prompt"] as? String ?? "",
                                    newWorktree: args["new_worktree"] as? Bool ?? false)
        _ = try Self.checkStart(folder: automation.folder, agentID: automation.agentID, prompt: automation.prompt)
        let folder = automation.folder
        if automation.newWorktree, await inBackground({ Git.repository(at: folder) }) == nil {
            throw ToolError(message: "\(folder) isn't in a git repository, so it can't have worktrees")
        }
        guard let frequency = Automation.Frequency(rawValue: args["repeat"] as? String ?? "") else {
            throw ToolError(message: "repeat must be hourly, daily, weekdays or weekly")
        }
        automation.frequency = frequency
        if let time = args["time"] as? String {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
                throw ToolError(message: "time must be HH:MM, such as 09:30")
            }
            automation.hour = parts[0]
            automation.minute = parts[1]
        }
        if let day = args["weekday"] as? String {
            guard let index = AgentTool.weekdays.firstIndex(of: day.lowercased()) else {
                throw ToolError(message: "Unknown weekday \(day)")
            }
            automation.weekday = index + 1
        }
        saveAutomation(automation)
        return automations.first { $0.id == automation.id } ?? automation
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

    private func describe(_ automation: Automation) -> [String: Any] {
        [
            "id": automation.id.uuidString, "name": automation.title, "prompt": automation.prompt,
            "schedule": automation.schedule, "paused": automation.isEnabled ? nil : true,
            "next_run": automation.nextRun?.formatted(date: .complete, time: .shortened),
            "last_run": automation.lastRun?.formatted(date: .complete, time: .shortened),
            "last_error": automation.lastError, "folder": automation.folder,
            "agent": automation.agentName, "new_worktree": automation.newWorktree,
        ].compactMapValues { $0 }
    }

    private func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               as: UTF8.self)
    }
}
