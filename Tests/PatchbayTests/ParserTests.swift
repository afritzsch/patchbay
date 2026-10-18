import AppKit
import Testing
@testable import Patchbay

struct GitParserTests {
    @Test func status() {
        let status = [
            "# branch.oid 1234567890abcdef",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaa bbb Sources/a file.swift",
            "2 R. N... 100644 100644 100644 aaa bbb R100 new.swift", "old.swift",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt",
            "? notes.md",
        ].joined(separator: "\0") + "\0"
        let info = Git.parse(status: status, root: "/repo")
        #expect(info.branch == "main")
        #expect(info.ahead == 2)
        #expect(info.behind == 1)
        #expect(info.changes == [
            GitChange(index: " ", worktree: "M", path: "Sources/a file.swift"),
            GitChange(index: "R", worktree: " ", path: "new.swift"),
            GitChange(index: "U", worktree: "U", path: "conflict.txt"),
            GitChange(index: "?", worktree: "?", path: "notes.md"),
        ])
        #expect(info.changes.map(\.isStaged) == [false, true, false, false])
        #expect(info.changes.map(\.isUnstaged) == [true, false, true, true])
    }

    @Test func branchName() {
        #expect(Git.branchName(for: "Fix login bug!") == "fix-login-bug")
        #expect(Git.branchName(for: "  Über 2.0 ") == "über-2-0")
        #expect(Git.branchName(for: "") == "")
    }

    @Test func worktreePath() {
        let repo = GitRepo(root: "/src/patchbay", current: "main", branches: ["main"])
        #expect(repo.worktreePath(for: "patchbay/abc") == NSHomeDirectory() + "/.patchbay/worktrees/patchbay/patchbay/abc")
    }

    @Test func agentCommandLine() {
        #expect(Agent.claude.commandLine(arguments: ["--resume", "abc"], prompt: "it's done?")
                == #"claude '--resume' 'abc' 'it'\''s done?'"#)
        #expect(Agent.named("gemini")?.commandLine(prompt: "hi") == "gemini -i 'hi'")
        #expect(Agent(id: "x", name: "X", command: "x").commandLine(prompt: "ignored") == "x")
    }

    @Test func worktreeSetupCopiesExistingFiles() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try FileManager.default.createDirectory(atPath: temp + "/main/config", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: temp + "/worktree", withIntermediateDirectories: true)
        try "SECRET=1".write(toFile: temp + "/main/config/.env", atomically: true, encoding: .utf8)
        let setup = try JSONDecoder().decode(WorktreeSetup.self, from: Data(#"{"copy": ["config/.env", "missing"]}"#.utf8))
        setup.copyFiles(from: temp + "/main", to: temp + "/worktree")
        #expect(try String(contentsOfFile: temp + "/worktree/config/.env", encoding: .utf8) == "SECRET=1")
        #expect(!FileManager.default.fileExists(atPath: temp + "/worktree/missing"))
    }

    @Test func detachedHead() {
        let info = Git.parse(status: "# branch.oid abcdef123456\0# branch.head (detached)\0", root: "/repo")
        #expect(info.branch == "abcdef1")
        #expect(info.changed == 0)
    }

    @Test func diff() {
        let diff = """
        diff --git a/x b/x
        index 1111111..2222222 100644
        --- a/x
        +++ b/x
        @@ -3,2 +3,3 @@ func
         keep
        -old
        +new
        +added
        """
        let lines = Git.parseDiff(diff)
        #expect(lines.map(\.kind) == [.hunk, .context, .removed, .added, .added])
        #expect(lines.map(\.old) == [nil, 3, 4, nil, nil])
        #expect(lines.map(\.new) == [nil, 3, nil, 4, 5])
        #expect(lines[2].text == "old")
    }

    @Test func reviewMessage() {
        let lines = Git.parseDiff("@@ -3,2 +3,3 @@\n same\n-old\n+new\n+more\n")
        let comments = [
            ReviewComment(path: "a.swift", lines: lines[1...1], text: "why?"),
            ReviewComment(path: "a.swift", lines: lines[1...4], text: " two\nlines "),
            ReviewComment(path: "b.swift", lines: lines[2...2], text: "keep this"),
        ]
        #expect(comments.map(\.lines) == ["3", "3-5", "4 (removed)"])
        #expect(ReviewComment.message(comments) == """
            Review comments:
            - a.swift:3: why?
            - a.swift:3-5: two
              lines
            - b.swift:4 (removed): keep this
            """)
    }
}

struct SmallParserTests {
    @Test func carriedArguments() {
        let args = ["--model", "opus", "--resume", "x", "--verbose", "--effort=high", "-c"]
        #expect(ExternalSessionScanner.carriedArgs(from: args) == ["--model", "opus", "--verbose", "--effort=high"])
    }

    @Test func runningAgent() {
        #expect(Agent.running("claude --resume x") == .claude)
        #expect(Agent.running("claudette") == nil)
        #expect(Agent.running("codex")?.id == "codex")
        #expect(Agent.claude.hasHooks)
        #expect(Agent.running("gemini")?.hasHooks == false)
    }

    @Test func shellEscaping() {
        #expect(TerminalHostView.shellEscaped("/a b/it's") == #"/a\ b/it\'s"#)
        #expect(ShellIntegration.quote("it's") == #"'it'\''s'"#)
    }

    @Test func dropZones() {
        let bounds = NSRect(x: 0, y: 0, width: 100, height: 100)
        #expect(TerminalHostView.zone(at: NSPoint(x: 5, y: 50), in: bounds) == .left)
        #expect(TerminalHostView.zone(at: NSPoint(x: 50, y: 50), in: bounds) == .center)
        #expect(TerminalHostView.zone(at: NSPoint(x: 50, y: 95), in: bounds) == .top) // AppKit's y grows upwards
        #expect(TerminalHostView.zone(at: NSPoint(x: 50, y: 5), in: bounds) == .bottom)
    }

    @Test func eventFileStartsOver() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        func append(_ text: String) throws { // like the writers' `>>`
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let reader = EventFileReader(url: url, limit: 10)
        try append("Stop\t{}\nShellPrompt\t0")
        let late = try FileHandle(forWritingTo: url) // a writer that opened the file just before it starts over
        #expect(reader.readNewLines() == ["Stop\t{}"])
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int == 0)
        try late.seekToEnd()
        try late.write(contentsOf: Data("\t/tmp\n".utf8))
        try append("ShellExec\tls\n")
        #expect(reader.readNewLines() == ["ShellPrompt\t0\t/tmp", "ShellExec\tls"])
    }

    @Test func elapsedTime() {
        #expect(ElapsedText.format(42) == "42s")
        #expect(ElapsedText.format(150) == "2m")
        #expect(ElapsedText.format(7200) == "2h")
    }
}

struct SyntaxTests {
    private func tokens(_ text: String, path: String) -> [String] {
        let string = text as NSString
        return Syntax(path: path)!.tokens(in: text).map { "\($0.token):\(string.substring(with: $0.range))" }
    }

    @Test func swift() {
        #expect(tokens(#"@MainActor let x: Int = 42 // done"#, path: "a.swift")
            == ["attribute:@MainActor", "keyword:let", "type:Int", "number:42", "comment:// done"])
        #expect(tokens(#"s = "a \"b\" c" + ""#, path: "a.swift") == [#"string:"a \"b\" c""#, #"string:""#])
        #expect(tokens("/* one\ntwo */ x", path: "a.swift") == ["comment:/* one\ntwo */"])
        #expect(tokens("\"\"\"\nmulti\n\"\"\"", path: "a.swift") == ["string:\"\"\"\nmulti\n\"\"\""])
    }

    @Test func hashComments() {
        #expect(tokens("echo $# # count", path: "run.sh") == ["comment:# count"])
        #expect(tokens("def f(): return None", path: "a.py") == ["keyword:def", "keyword:return", "keyword:None"])
        #expect(Syntax(path: "Makefile") != nil)
        #expect(Syntax(path: "notes.txt") == nil)
    }

    @Test func unclosedString() {
        // Stops at the line end instead of swallowing the rest of the file.
        #expect(tokens("x = 'it\ny = 1", path: "a.js") == ["string:'it", "number:1"])
    }
}

struct LineChangesTests {
    @Test func addedChangedRemoved() {
        let old = "a\nb\nc\nd\ne"
        // b changed, a line after c added, e removed.
        let changes = Git.lineChanges(from: old, to: "a\nB\nc\nnew\nd")
        #expect(changes.added == [1, 3])
        #expect(changes.removed == [5])
        #expect(Git.lineChanges(from: old, to: "a\nd\ne") == LineChanges(added: [], removed: [1]))
        #expect(Git.lineChanges(from: "", to: "x\ny") == LineChanges(added: [0, 1], removed: []))
        #expect(Git.lineChanges(from: "x\r\ny", to: "x\r\ny") == LineChanges())
    }
}
