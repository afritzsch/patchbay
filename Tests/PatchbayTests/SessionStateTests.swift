import Foundation
import Testing
@testable import Patchbay

/// Event sequences as the shell integration and Claude Code's hooks write them, and the status they lead to.
struct SessionStateTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    /// A Claude session that has started and is waiting for a prompt.
    func claudeReady() -> SessionState {
        var state = SessionState(cwd: "/tmp")
        _ = state.apply(.shellExec, payload: "claude", visible: true, now: start)
        _ = state.apply(.sessionStart, payload: #"{"session_id":"abc","cwd":"/repo"}"#, visible: true, now: start)
        return state
    }

    func submit(_ prompt: String, to state: inout SessionState) -> [SessionState.Effect] {
        state.apply(.userPromptSubmit, payload: #"{"prompt":"\#(prompt)","session_id":"abc"}"#, visible: true, now: start)
    }

    @Test func claudeTurn() {
        var state = claudeReady()
        #expect(state.status == .agentReady)
        #expect(state.isClaude)
        #expect(state.conversationID == "abc")
        #expect(state.cwd == "/repo")

        #expect(submit(" fix it ", to: &state) == [.record(.prompt, "fix it")])
        #expect(state.status == .agentWorking)
        _ = state.apply(.preToolUse, payload: #"{"tool_name":"Bash"}"#, visible: true, now: start)
        #expect(state.statusLabel == "Working · Bash")

        let effects = state.apply(.stop, payload: "{}", visible: false, now: start + 30)
        #expect(state.status == .agentDone)
        #expect(state.unseen)
        #expect(effects == [.record(.agentFinished, "fix it", duration: 30), .gitChanged, .alert("Done: fix it")])
    }

    @Test func finishingWhileLookingDoesNotNotify() {
        var state = claudeReady()
        _ = submit("hi", to: &state)
        #expect(state.apply(.stop, payload: "{}", visible: true, now: start) == [.record(.agentFinished, "hi", duration: 0), .gitChanged])
        #expect(!state.unseen)
    }

    @Test func permissionPromptThenIdleReminder() {
        var state = claudeReady()
        _ = submit("deploy", to: &state)
        let question = "Claude needs your permission to use Bash"
        let effects = state.apply(.notification, payload: #"{"message":"\#(question)"}"#, visible: true, now: start)
        #expect(effects == [.record(.agentNeedsInput, question), .alert(question)])
        #expect(state.status == .agentNeedsInput)
        #expect(state.needsAttention)

        state.inputSent(now: start)
        #expect(state.status == .agentWorking)
        #expect(state.message == nil)

        _ = state.apply(.stop, payload: "{}", visible: true, now: start)
        let reminder = #"{"message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#
        #expect(state.apply(.notification, payload: reminder, visible: true, now: start).isEmpty)
        #expect(state.status == .agentDone)
    }

    /// What `wait_for` relies on: right after a prompt is sent, the session doesn't still look finished or ready.
    @Test func sentPromptCountsAsWorking() {
        var state = claudeReady()
        _ = submit("hi", to: &state)
        _ = state.apply(.stop, payload: "{}", visible: true, now: start)
        state.promptSent("next", now: start)
        #expect(state.status == .agentWorking)

        var starting = SessionState(cwd: "/tmp", agent: .claude)
        starting.promptSent("first", now: start)
        _ = starting.apply(.shellExec, payload: "claude 'first'", visible: true, now: start)
        _ = starting.apply(.sessionStart, payload: "{}", visible: true, now: start)
        #expect(starting.status == .agentWorking)
        _ = starting.apply(.sessionStart, payload: "{}", visible: true, now: start) // e.g. after /clear
        #expect(starting.status == .agentReady)

        var shell = SessionState(cwd: "/tmp")
        _ = shell.apply(.shellPrompt, payload: "0\t/tmp", visible: true, now: start)
        shell.promptSent("make", now: start)
        #expect(shell.isWorking)
    }

    @Test func silenceMeansInterrupted() {
        var state = claudeReady()
        _ = submit("go", to: &state)
        state.checkForSilence(lastOutput: start, now: start + 5)
        #expect(state.status == .agentWorking)
        state.checkForSilence(lastOutput: start, now: start + 9)
        #expect(state.status == .agentReady)
    }

    @Test func runningSubagentIsNotSilence() {
        var state = claudeReady()
        _ = submit("research", to: &state)
        _ = state.apply(.preToolUse, payload: #"{"tool_name":"Task"}"#, visible: true, now: start)
        state.checkForSilence(lastOutput: start, now: start + 60)
        #expect(state.status == .agentWorking)
        #expect(state.statusLabel == "Waiting for agent")
        _ = state.apply(.postToolUse, payload: #"{"tool_name":"Task"}"#, visible: true, now: start + 60)
        #expect(state.runningSubagents == 0)
    }

    @Test func quittingMidSubagentForgetsIt() {
        var state = claudeReady()
        _ = submit("research", to: &state)
        _ = state.apply(.preToolUse, payload: #"{"tool_name":"Task"}"#, visible: true, now: start)
        _ = state.apply(.shellPrompt, payload: "130\t/repo", visible: true, now: start + 5)
        #expect(state.runningSubagents == 0)
    }

    @Test func agentWithoutHooksFollowsItsOutput() {
        var state = SessionState(cwd: "/tmp")
        _ = state.apply(.shellExec, payload: "codex --full-auto", visible: true, now: start)
        #expect(state.agent?.id == "codex")
        #expect(state.status == .agentWorking)

        state.checkForSilence(lastOutput: start, now: start + 9)
        #expect(state.status == .agentReady)
        state.outputReceived(sinceInput: 0.1, now: start + 10) // the echo of typing
        #expect(state.status == .agentReady)
        state.outputReceived(sinceInput: 2, now: start + 11)
        #expect(state.status == .agentWorking)
        #expect(state.bellRang(visible: false) == [.alert("Bell")])
    }

    @Test func commandsAndTheirExitCodes() {
        var state = SessionState(cwd: "/tmp")
        _ = state.apply(.shellExec, payload: "make", visible: false, now: start)
        #expect(state.status == .running("make"))
        let effects = state.apply(.shellPrompt, payload: "2\t/src", visible: false, now: start + 20)
        #expect(effects == [.record(.command, "make", exitCode: 2, duration: 20), .alert("Failed (exit 2): make"), .gitChanged])
        #expect(state.status == .idle)
        #expect(state.cwd == "/src")
        #expect(state.unseen)

        // A quick command needs no notification.
        _ = state.apply(.shellExec, payload: "ls", visible: false, now: start + 30)
        #expect(state.apply(.shellPrompt, payload: "0\t/src", visible: false, now: start + 31)
                == [.record(.command, "ls", exitCode: 0, duration: 1), .gitChanged])
    }

    @Test func exitedSessionIsNotAlive() {
        var state = claudeReady()
        state.processExited(0)
        #expect(!state.isAlive)
        #expect(state.agent == nil)
    }

    @Test func truncatedHookPayload() {
        // The hook script cuts payloads off at 4000 characters, which leaves the JSON unparseable.
        let payload = HookPayload(#"{"session_id":"abc","prompt":"line one\nline \"two\"","tool_input":{"content":"cut off her"#)
        #expect(payload["session_id"] == "abc")
        #expect(payload["prompt"] == "line one\nline \"two\"")
        #expect(payload["missing"] == nil)
    }
}

/// OpenCode reports through a plugin that writes Claude-shaped event lines (plus AgentResumed and AgentReady).
struct OpenCodeStateTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func ready() -> SessionState {
        var state = SessionState(cwd: "/tmp")
        _ = state.apply(.shellExec, payload: "opencode", visible: true, now: start)
        _ = state.apply(.sessionStart, payload: #"{"cwd":"/repo"}"#, visible: true, now: start)
        return state
    }

    func working(_ prompt: String = "fix it") -> SessionState {
        var state = ready()
        _ = state.apply(.userPromptSubmit, payload: #"{"session_id":"ses_1","prompt":"\#(prompt)"}"#, visible: true, now: start)
        return state
    }

    @Test func startsReady() {
        var state = SessionState(cwd: "/tmp")
        _ = state.apply(.shellExec, payload: "opencode", visible: true, now: start)
        #expect(state.agent?.id == "opencode")
        #expect(state.status == .running("opencode"))

        #expect(state.apply(.sessionStart, payload: #"{"cwd":"/repo"}"#, visible: true, now: start).isEmpty)
        #expect(state.status == .agentReady)
        #expect(state.agent?.id == "opencode")
        #expect(!state.isClaude)
        #expect(state.cwd == "/repo")
    }

    @Test func promptAndTools() {
        var state = ready()
        let effects = state.apply(.userPromptSubmit, payload: #"{"session_id":"ses_1","prompt":" fix it "}"#, visible: true, now: start)
        #expect(effects == [.record(.prompt, "fix it")])
        #expect(state.status == .agentWorking)
        #expect(state.lastPrompt == "fix it")

        _ = state.apply(.preToolUse, payload: #"{"session_id":"ses_1","tool_name":"edit"}"#, visible: true, now: start)
        #expect(state.statusLabel == "Working · edit")
        #expect(state.apply(.postToolUse, payload: #"{"session_id":"ses_1","tool_name":"edit"}"#, visible: true, now: start) == [.gitChanged])
        #expect(state.statusLabel == "Working")
        #expect(state.agent?.id == "opencode")
    }

    @Test func promptSetsTheOpenCodeConversation() {
        var state = ready()
        #expect(state.conversationID == nil) // SessionStart carries no session ID.
        _ = state.apply(.userPromptSubmit, payload: #"{"session_id":"ses_1","prompt":"hi"}"#, visible: true, now: start)
        #expect(state.conversationID == "ses_1")
        #expect(state.conversationAgentID == "opencode")
        #expect(state.conversation(of: .opencode) == "ses_1")
        #expect(state.conversation(of: .claude) == nil)
        #expect(state.runningConversationID == "ses_1")

        // The TUI switched sessions: the latest prompt's wins.
        _ = state.apply(.userPromptSubmit, payload: #"{"session_id":"ses_2","prompt":"again"}"#, visible: true, now: start)
        #expect(state.conversationID == "ses_2")
    }

    @Test func otherEventsDoNotChangeTheOpenCodeConversation() {
        var state = working()
        #expect(state.conversationID == "ses_1")
        let child = #"{"session_id":"ses_child","tool_name":"bash","command":"ls","message":"Permission required"}"#
        for event in [SessionEvent.preToolUse, .postToolUse, .permissionRequest, .notification, .agentResumed, .agentReady, .stop] {
            _ = state.apply(event, payload: child, visible: true, now: start)
        }
        _ = state.apply(.sessionStart, payload: #"{"session_id":"ses_child","cwd":"/repo"}"#, visible: true, now: start)
        // A prompt without text isn't a prompt.
        _ = state.apply(.userPromptSubmit, payload: #"{"session_id":"ses_child","prompt":" "}"#, visible: true, now: start)
        #expect(state.conversationID == "ses_1")
    }

    @Test func conversationBelongsToItsAgentAfterItExits() {
        var state = working()
        _ = state.apply(.shellPrompt, payload: "0", visible: true, now: start + 5)
        #expect(state.agent == nil)
        #expect(state.conversation(of: .opencode) == "ses_1") // History still records it, as OpenCode's.
        #expect(state.conversation(of: .claude) == nil)
        #expect(state.runningConversationID == nil) // Nothing runs it now, so nothing is saved for restore.
    }

    @Test func restoredSessionKeepsItsConversation() {
        let state = SessionState(cwd: "/tmp", agent: .opencode, conversationID: "ses_9")
        #expect(state.runningConversationID == "ses_9")
        #expect(SessionState(cwd: "/tmp", agent: .claude, conversationID: "abc").conversation(of: .opencode) == nil)
    }

    @Test func claudeConversationIsNotOpenCodes() {
        var claude = SessionStateTests().claudeReady()
        _ = SessionStateTests().submit("hi", to: &claude)
        #expect(claude.conversationID == "abc")
        #expect(claude.conversation(of: .claude) == "abc")
        #expect(claude.conversation(of: .opencode) == nil)
    }

    @Test func permissionThenResumed() {
        var state = working()
        let request = #"{"session_id":"ses_1","tool_name":"bash","command":"/repo/scripts/deploy.sh","cwd":"/repo"}"#
        #expect(state.apply(.permissionRequest, payload: request, visible: true, now: start) == [])
        #expect(state.status == .agentNeedsInput)
        #expect(state.asksApproval)
        #expect(state.approvalRequest == "bash: scripts/deploy.sh")
        #expect(state.statusLabel == "Asks permission")

        let effects = state.apply(.notification, payload: #"{"session_id":"ses_1","message":"Permission required"}"#, visible: true, now: start)
        #expect(effects == [.record(.agentNeedsInput, "Allow bash: scripts/deploy.sh?"), .alert("Allow bash: scripts/deploy.sh?")])

        #expect(state.apply(.agentResumed, payload: #"{"session_id":"ses_1"}"#, visible: true, now: start + 3).isEmpty)
        #expect(state.status == .agentWorking)
        #expect(!state.asksApproval)
        #expect(state.approvalRequest == nil)
        #expect(state.message == nil)
    }

    @Test func questionNeedsInputThenResumed() {
        var state = working()
        let effects = state.apply(.notification, payload: #"{"session_id":"ses_1","message":"Which database?"}"#, visible: false, now: start)
        #expect(effects == [.record(.agentNeedsInput, "Which database?"), .alert("Which database?")])
        #expect(state.status == .agentNeedsInput)
        #expect(state.statusLabel == "Needs your input")

        // A keypress in the form isn't an answer: the plugin reports that.
        state.inputSent(now: start + 1)
        #expect(state.status == .agentNeedsInput)
        _ = state.apply(.agentResumed, payload: "{}", visible: true, now: start + 2)
        #expect(state.status == .agentWorking)
    }

    @Test func notificationWithoutTextNamesTheAgent() {
        var state = working()
        let effects = state.apply(.notification, payload: "{}", visible: true, now: start)
        #expect(effects == [.record(.agentNeedsInput, "OpenCode needs your attention"), .alert("OpenCode needs your attention")])
    }

    @Test func resumedWhileWorkingChangesNothing() {
        var state = working()
        _ = state.apply(.agentResumed, payload: "{}", visible: true, now: start)
        #expect(state.status == .agentWorking)
    }

    @Test func stopFinishesTheTurn() {
        var state = working()
        _ = state.apply(.preToolUse, payload: #"{"tool_name":"bash"}"#, visible: true, now: start)
        let effects = state.apply(.stop, payload: #"{"session_id":"ses_1"}"#, visible: false, now: start + 20)
        #expect(state.status == .agentDone)
        #expect(state.unseen)
        #expect(state.currentTool == nil)
        #expect(effects == [.record(.agentFinished, "fix it", duration: 20), .gitChanged, .alert("Done: fix it")])

        var looking = working()
        #expect(looking.apply(.stop, payload: "{}", visible: true, now: start) == [.record(.agentFinished, "fix it", duration: 0), .gitChanged])
        #expect(!looking.unseen)
    }

    @Test func interruptionMeansReady() {
        var state = working()
        _ = state.apply(.preToolUse, payload: #"{"tool_name":"bash"}"#, visible: true, now: start)
        #expect(state.apply(.agentReady, payload: #"{"session_id":"ses_1"}"#, visible: false, now: start + 5).isEmpty)
        #expect(state.status == .agentReady)
        #expect(state.currentTool == nil)
        #expect(state.message == nil)
        #expect(!state.unseen)

        // The next prompt starts a turn again.
        _ = state.apply(.userPromptSubmit, payload: #"{"session_id":"ses_1","prompt":"again"}"#, visible: true, now: start + 6)
        #expect(state.status == .agentWorking)
    }

    @Test func failureShowsItsMessage() {
        var state = working()
        let effects = state.apply(.agentReady, payload: #"{"session_id":"ses_1","message":"Rate limited"}"#, visible: false, now: start + 5)
        #expect(state.status == .agentReady)
        #expect(state.message == "Rate limited")
        #expect(state.unseen)
        #expect(effects == [.alert("Rate limited")])

        var looking = working()
        #expect(looking.apply(.agentReady, payload: #"{"message":"Rate limited"}"#, visible: true, now: start).isEmpty)
        #expect(looking.message == "Rate limited")
        #expect(!looking.unseen)
    }

    @Test func subagentKeepsTheParentWorkingWithoutSilenceFallback() {
        var state = working("research")
        _ = state.apply(.preToolUse, payload: #"{"session_id":"ses_2","tool_name":"task"}"#, visible: true, now: start)
        #expect(state.runningSubagents == 1)
        #expect(state.statusLabel == "Waiting for agent")
        state.checkForSilence(lastOutput: start, now: start + 600)
        #expect(state.status == .agentWorking)
        _ = state.apply(.postToolUse, payload: #"{"session_id":"ses_2","tool_name":"task"}"#, visible: true, now: start + 600)
        #expect(state.runningSubagents == 0)
        #expect(state.status == .agentWorking)
    }

    @Test func silenceIsNotAnInterruption() {
        var state = working()
        state.checkForSilence(lastOutput: start, now: start + 120)
        #expect(state.status == .agentWorking)

        // Claude's rule is unchanged.
        var claude = SessionStateTests().claudeReady()
        _ = SessionStateTests().submit("go", to: &claude)
        claude.checkForSilence(lastOutput: start, now: start + 9)
        #expect(claude.status == .agentReady)
    }

    @Test func hookLinesDoNotTurnItIntoClaude() {
        var state = working()
        for (event, payload) in [(SessionEvent.preToolUse, #"{"tool_name":"read"}"#), (.postToolUse, #"{"tool_name":"read"}"#),
                                 (.notification, #"{"message":"?"}"#), (.permissionRequest, #"{"tool_name":"edit"}"#),
                                 (.agentResumed, "{}"), (.stop, "{}"), (.agentReady, "{}"), (.sessionStart, "{}")] {
            _ = state.apply(event, payload: payload, visible: true, now: start)
            #expect(state.agent?.id == "opencode")
        }
    }

    @Test func recognisedFromACompoundCommandLine() {
        // `cd app && opencode`: the shell reported the whole line, which isn't the agent's command.
        var state = SessionState(cwd: "/tmp")
        _ = state.apply(.shellExec, payload: "cd app && opencode", visible: true, now: start)
        #expect(state.agent == nil)
        _ = state.apply(.sessionStart, payload: "{}", visible: true, now: start)
        #expect(state.agent?.id == "opencode")

        var claude = SessionState(cwd: "/tmp")
        _ = claude.apply(.shellExec, payload: "cd app && claude", visible: true, now: start)
        _ = claude.apply(.sessionStart, payload: "{}", visible: true, now: start)
        #expect(claude.isClaude)
    }

    @Test func leavingOpenCodeGoesBackToTheShell() {
        var state = working()
        _ = state.apply(.shellPrompt, payload: "0\t/repo", visible: true, now: start + 9)
        #expect(state.agent == nil)
        #expect(state.status == .idle)
    }

    @Test func bellAndOutputUseTheHooks() {
        var state = ready()
        #expect(state.bellRang(visible: false).isEmpty)
        state.outputReceived(sinceInput: 5, now: start + 1)
        #expect(state.status == .agentReady)
    }

    @Test func promptFlagCommandLine() {
        let agent = Agent.named("opencode")
        #expect(agent == .opencode)
        #expect(agent?.hasHooks == true)
        #expect(agent?.approval == Agent.Approval(prompt: "Permission required", allow: "enter", deny: "esc"))
        #expect(Agent.opencode.commandLine(prompt: "fix the bug") == "opencode --prompt 'fix the bug'")
        #expect(Agent.opencode.commandLine() == "opencode")
        #expect(Agent.opencode.commandLine(resuming: "ses_1") == "opencode --session 'ses_1'")
        #expect(Agent.opencode.commandLine(resuming: "ses_1", prompt: "go on") == "opencode --session 'ses_1' --prompt 'go on'")
        #expect(Agent.claude.commandLine(resuming: "abc", arguments: ["--model", "opus"]) == "claude --resume 'abc' '--model' 'opus'")
        #expect(Agent.named("gemini")?.commandLine(resuming: "x") == "gemini")
        #expect(Agent.running("opencode --session ses_1") == .opencode)
        // The other styles are as before.
        #expect(Agent.claude.commandLine(prompt: "hi") == "claude 'hi'")
        #expect(Agent.named("gemini")?.commandLine(prompt: "hi") == "gemini -i 'hi'")
    }

    @Test func savedCustomAgentsStillDecode() throws {
        let json = #"[{"id":"a","name":"Mine","command":"mine","promptStyle":"interactiveFlag"},"#
            + #"{"id":"b","name":"Other","command":"other","promptStyle":"argument"},"#
            + #"{"id":"c","name":"None","command":"none","promptStyle":"unsupported"},"#
            + #"{"id":"d","name":"Flag","command":"flag","promptStyle":"promptFlag"}]"#
        let agents = try JSONDecoder().decode([Agent].self, from: Data(json.utf8))
        #expect(agents.map(\.promptStyle) == [.interactiveFlag, .argument, .unsupported, .promptFlag])
        #expect(agents.allSatisfy { !$0.hasHooks })
        let encoded = try JSONEncoder().encode(agents[3])
        #expect(try JSONDecoder().decode(Agent.self, from: encoded) == agents[3])
    }

    @Test func claudeSettingsOnlyListClaudeHooks() {
        #expect(!SessionEvent.hooks.contains(.agentResumed))
        #expect(!SessionEvent.hooks.contains(.agentReady))
        #expect(!SessionEvent.hooks.contains(.shellExec))
        #expect(SessionEvent.hooks.contains(.permissionRequest))
        #expect(SessionEvent.hooks.contains(.sessionEnd))
    }
}

/// Permission prompts: reported by Claude's hook or seen on screen, answered from the app or the terminal.
struct ApprovalTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func claudeRequestFromHook() {
        var state = SessionStateTests().claudeReady()
        _ = SessionStateTests().submit("build", to: &state)
        let request = #"{"cwd":"/repo","tool_name":"Edit","tool_input":{"file_path":"/repo/Sources/a.swift","old_string":"x"#
        #expect(state.apply(.permissionRequest, payload: request, visible: true, now: start) == [])
        #expect(state.asksApproval)
        #expect(state.status == .agentNeedsInput)
        #expect(state.approvalRequest == "Edit: Sources/a.swift")
        #expect(state.statusLabel == "Asks permission")

        let effects = state.apply(.notification, payload: #"{"message":"Claude needs your permission"}"#, visible: true, now: start)
        #expect(effects == [.record(.agentNeedsInput, "Allow Edit: Sources/a.swift?"), .alert("Allow Edit: Sources/a.swift?")])

        _ = state.apply(.postToolUse, payload: #"{"tool_name":"Edit"}"#, visible: true, now: start + 2)
        #expect(!state.asksApproval)
        #expect(state.status == .agentWorking)
    }

    @Test func agentWithoutHooksSeenAsking() {
        var state = SessionState(cwd: "/repo")
        _ = state.apply(.shellExec, payload: "codex", visible: true, now: start)
        #expect(state.status == .agentWorking)

        #expect(state.approvalPrompt(shown: true, now: start + 2) == [.alert("Codex asks for permission")])
        #expect(state.status == .agentNeedsInput)
        #expect(state.needsAttention)

        // Answered in the terminal: the prompt is gone after the next redraw.
        _ = state.approvalPrompt(shown: false, now: start + 4)
        #expect(!state.asksApproval)
        #expect(state.status == .agentWorking)
    }

    @Test func answeringClearsTheRequest() {
        var state = SessionState(cwd: "/repo")
        _ = state.apply(.shellExec, payload: "gemini", visible: true, now: start)
        _ = state.approvalPrompt(shown: true, now: start + 1)
        state.inputSent(now: start + 2)
        #expect(!state.asksApproval)
        #expect(state.status == .agentWorking)
    }

    @Test func promptOnScreen() {
        let codex = Agent.named("codex")!.approval!
        #expect(codex.isShown(on: "│ ❯ 1. Yes, proceed\n│   3. No, and tell Codex what to do differently (esc) │"))
        // Wrapped inside the box in a narrow pane.
        #expect(codex.isShown(on: "│ 3. No, and tell Codex what   │\n│    to do differently (esc)     │"))
        #expect(!codex.isShown(on: "Tell Codex what you want"))
        #expect(!Agent.Approval(prompt: "", allow: "y", deny: "n").isShown(on: "anything"))
        #expect(Agent.Approval.keys("Esc") == "\u{1b}")
        #expect(Agent.Approval.keys("y") == "y")
    }

    @Test func requestSummary() {
        #expect(ClaudeCode.requestSummary(HookPayload(#"{"tool_name":"Bash","tool_input":{"command":"npm test"}}"#)) == "Bash: npm test")
        #expect(ClaudeCode.requestSummary(HookPayload(#"{"tool_name":"mcp__x__y","tool_input":{}}"#)) == "mcp__x__y")
        #expect(ClaudeCode.requestSummary(HookPayload("{}")) == nil)
    }
}
