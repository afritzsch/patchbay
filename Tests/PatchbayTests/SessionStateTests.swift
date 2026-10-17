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
        #expect(state.claudeSessionID == "abc")
        #expect(state.cwd == "/repo")

        #expect(submit(" fix it ", to: &state) == [.record(.prompt, "fix it")])
        #expect(state.status == .agentWorking)
        _ = state.apply(.preToolUse, payload: #"{"tool_name":"Bash"}"#, visible: true, now: start)
        #expect(state.statusLabel == "Working · Bash")

        let effects = state.apply(.stop, payload: "{}", visible: false, now: start + 30)
        #expect(state.status == .agentDone)
        #expect(state.unseen)
        #expect(effects == [.record(.claudeFinished, "fix it", duration: 30), .gitChanged, .alert("Done: fix it")])
    }

    @Test func finishingWhileLookingDoesNotNotify() {
        var state = claudeReady()
        _ = submit("hi", to: &state)
        #expect(state.apply(.stop, payload: "{}", visible: true, now: start) == [.record(.claudeFinished, "hi", duration: 0), .gitChanged])
        #expect(!state.unseen)
    }

    @Test func permissionPromptThenIdleReminder() {
        var state = claudeReady()
        _ = submit("deploy", to: &state)
        let question = "Claude needs your permission to use Bash"
        let effects = state.apply(.notification, payload: #"{"message":"\#(question)"}"#, visible: true, now: start)
        #expect(effects == [.record(.claudeNeedsInput, question), .alert(question)])
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
