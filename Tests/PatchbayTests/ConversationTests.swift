import Foundation
import Testing
@testable import Patchbay

/// Conversation IDs kept per agent: what's saved, what History records, and what restore resumes.
struct ConversationTests {
    @Test func savedSessionFromEarlierReleaseDecodes() throws {
        let json = #"[{"id":"7A2F4B4E-5C5B-4B7B-9D43-2F6E6A0A9C11","directory":"/repo","agentID":"claude","claudeSessionID":"abc"},"#
            + #"{"directory":"/tmp","claude":false}]"#
        let saved = try JSONDecoder().decode([SessionStore.SavedSession].self, from: Data(json.utf8))
        #expect(saved[0].conversationID == "abc")
        #expect(saved[0].agentID == "claude")
        #expect(saved[1].conversationID == nil)
    }

    @Test func savedSessionKeepsTheOldKey() throws {
        let saved = SessionStore.SavedSession(directory: "/repo", agentID: "opencode", conversationID: "ses_1")
        let data = try JSONEncoder().encode(saved)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["claudeSessionID"] as? String == "ses_1")
        #expect(object["conversationID"] == nil)
        #expect(try JSONDecoder().decode(SessionStore.SavedSession.self, from: data).conversationID == "ses_1")
    }

    @Test func historyEntryFromEarlierReleaseIsClaudes() throws {
        let json = #"{"id":"7A2F4B4E-5C5B-4B7B-9D43-2F6E6A0A9C11","date":0,"kind":"prompt","#
            + #""sessionID":"1B2F4B4E-5C5B-4B7B-9D43-2F6E6A0A9C11","sessionName":"api","directory":"/repo","#
            + #""text":"fix it","agent":"Claude Code","claudeSessionID":"abc"}"#
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
        #expect(entry.conversationID == "abc")
        #expect(entry.conversationAgentID == nil)
        #expect(entry.conversation(of: .claude) == "abc")
        #expect(entry.conversation(of: .opencode) == nil)
    }

    @Test func historyEntryRoundTripsAnOpenCodeConversation() throws {
        let entry = HistoryEntry(kind: .prompt, sessionID: UUID(), sessionName: "api", directory: "/repo", text: "fix it",
                                 agent: "OpenCode", conversationID: "ses_1", conversationAgentID: "opencode")
        let data = try JSONEncoder().encode(entry)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["claudeSessionID"] as? String == "ses_1")
        let back = try JSONDecoder().decode(HistoryEntry.self, from: data)
        #expect(back == entry)
        #expect(back.conversation(of: .opencode) == "ses_1")
        #expect(back.conversation(of: .claude) == nil)
    }

    @Test func restoreResumesTheRightConversations() {
        let transcripts: (String) -> Bool = { $0 == "has-transcript" }
        func restorable(_ id: String?, _ agent: Agent?, resume: Bool = true) -> String? {
            SessionStore.restorableConversation(id, of: agent, resume: resume, claudeTranscriptExists: transcripts)
        }
        // Claude needs a transcript; OpenCode's --session creates the session if it's missing.
        #expect(restorable("has-transcript", .claude) == "has-transcript")
        #expect(restorable("nobody-typed", .claude) == nil)
        #expect(restorable("ses_1", .opencode) == "ses_1")
        #expect(restorable(nil, .opencode) == nil)
        #expect(restorable("ses_1", .opencode, resume: false) == nil)
        #expect(restorable("ses_1", Agent.named("codex")) == nil)
        #expect(restorable("ses_1", nil) == nil)
    }

    @Test func restoreCommandLines() {
        #expect(Agent.opencode.commandLine(resuming: "ses_1") == "opencode --session 'ses_1'")
        #expect(Agent.opencode.resumesConversations)
        #expect(Agent.claude.resumesConversations)
        #expect(Agent.named("codex")?.resumesConversations == false)
    }
}
