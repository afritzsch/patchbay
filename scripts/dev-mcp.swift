// MCP server for developing Patchbay (registered in .mcp.json). It builds and runs a separate test copy of the app
// (own support folder and defaults), drives it and takes snapshots. The app side is DevHooks.swift.
// MCP over stdio is JSON-RPC: one JSON message per line in, one per line out.
import AppKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let builtApp = repo.appending(path: "build/Patchbay.app")
let devDir = repo.appending(path: "build/dev")
let snapshotFile = devDir.appending(path: "snapshot.png")
let layoutFile = devDir.appending(path: "layout.txt")
let logFile = devDir.appending(path: "app.log")

struct ToolError: Error { let message: String }

/// The test copy is the built app with "Test" appended to its bundle ID and name. The app names its support
/// folder after the name and its defaults after the ID, so the copy can't touch the real app's data.
struct TestCopy {
    let id: String
    let name: String
    var app: URL { repo.appending(path: "build/\(name).app") }

    init() throws {
        let info = NSDictionary(contentsOf: builtApp.appending(path: "Contents/Info.plist"))
        guard let id = info?["CFBundleIdentifier"] as? String, let name = info?["CFBundleName"] as? String else {
            throw ToolError(message: "The app isn't built yet; call start_test_app.")
        }
        self.id = id + "Test"
        self.name = name + "Test"
    }
}

enum Tool: String, CaseIterable {
    case startTestApp = "start_test_app"
    case snapshot
    case typeText = "type_text"
    case clickMenu = "click_menu"
    case dropSession = "drop_session"
    case layout
    case openChange = "open_change"
    case logs
    case stopTestApp = "stop_test_app"

    var description: String {
        switch self {
        case .startTestApp: """
            Builds the app with build.sh and (re)launches it as a separate test copy, which can't touch the user's \
            real Patchbay. A running test copy is quit first and keeps its sessions, so this also tests restoring them. \
            A fresh copy has no sessions; click_menu "New Shell Here" opens one.
            """
        case .snapshot: "Returns a PNG of the test copy's window."
        case .typeText: "Types into the selected session of the test copy. End with \\n to press Return. A new shell needs about a second before it reads input."
        case .clickMenu: "Clicks a menu item of the test copy by exact title, e.g. \"Split Right\", \"New Shell Here\", \"Show Overview\"."
        case .dropSession: """
            Drops one session on another's pane, as dragging it there with the mouse would (drags can't be automated). \
            Sessions are numbered as in the sidebar from 1. Edges split the pane, the centre swaps or replaces it. \
            Returns the layout afterwards.
            """
        case .layout: """
            Returns the pane tree, sessions numbered as in the sidebar: H[…] is a row, V[…] a column, each child \
            followed by its share, e.g. H[1:0.50 V[2:0.50 3:0.50]:0.50]. Then each terminal's frame in window points.
            """
        case .openChange: """
            Opens the diff inspector for a changed file of the selected session, as clicking it in the Changes tab \
            would. The path is relative to the repository root.
            """
        case .logs: "Returns the end of the test copy's stdout and stderr (print and NSLog output)."
        case .stopTestApp: "Quits the test copy and deletes it, its support folder and its defaults, so the next start is fresh."
        }
    }

    var parameters: [String: Any] {
        switch self {
        case .typeText: ["text": ["type": "string"]]
        case .clickMenu: ["title": ["type": "string"]]
        case .dropSession: ["session": ["type": "integer"], "target": ["type": "integer"],
                            "zone": ["type": "string", "enum": ["left", "right", "top", "bottom", "center"]]]
        case .openChange: ["path": ["type": "string"], "staged": ["type": "boolean"]]
        case .logs: ["lines": ["type": "integer", "description": "How many lines (default 50)"]]
        default: [:]
        }
    }

    var schema: [String: Any] {
        ["name": rawValue, "description": description,
         "inputSchema": ["type": "object", "properties": parameters, "required": self == .logs ? [] : self == .openChange ? ["path"] : Array(parameters.keys)]]
    }
}

func call(_ tool: Tool, _ args: [String: Any]) throws -> [[String: Any]] {
    switch tool {
    case .startTestApp:
        do { try run("./build.sh") } catch let error as ToolError {
            let lines = error.message.split(separator: "\n")
            let errors = lines.filter { $0.contains("error:") }
            throw ToolError(message: "Build failed:\n" + (errors.isEmpty ? lines.suffix(30) : errors).joined(separator: "\n"))
        }
        let test = try TestCopy()
        quit(test)
        try? FileManager.default.removeItem(at: test.app)
        try FileManager.default.copyItem(at: builtApp, to: test.app)
        let plist = test.app.appending(path: "Contents/Info.plist").path
        try run("plutil", "-replace", "CFBundleIdentifier", "-string", test.id, plist)
        try run("plutil", "-replace", "CFBundleName", "-string", test.name, plist)
        try run("codesign", "--force", "--deep", "--sign", "-", test.app.path)
        try FileManager.default.createDirectory(at: devDir, withIntermediateDirectories: true)
        try run("open", "-n", "--env", "PATCHBAY_DEV_DIR=\(devDir.path)",
                "--stdout", logFile.path, "--stderr", logFile.path, test.app.path)
        guard wait(20, until: { (try? requestSnapshot(1)) == true }) else {
            throw ToolError(message: "The test copy didn't open its window; see `logs`.")
        }
        return [text("Test copy running. Seed settings with `defaults write \(test.id) …` before starting it.")]
    case .snapshot:
        guard try requestSnapshot(5) else { throw ToolError(message: "No snapshot arrived; is the window open?") }
        try run("sips", "-Z", "1600", snapshotFile.path)  // Retina size is needlessly large
        return [["type": "image", "mimeType": "image/png", "data": try Data(contentsOf: snapshotFile).base64EncodedString()]]
    case .typeText:
        try post("type", args["text"] as? String ?? "")
        return [text("Typed.")]
    case .clickMenu:
        try post("menu", args["title"] as? String ?? "")
        return [text("Clicked, unless `logs` says no such item exists.")]
    case .dropSession:
        try post("drop", "\(args["session"] as? Int ?? 0) \(args["target"] as? Int ?? 0) \(args["zone"] as? String ?? "")")
        Thread.sleep(forTimeInterval: 0.5)  // let the window lay out the new panes
        return [text(try requestLayout())]
    case .layout:
        return [text(try requestLayout())]
    case .openChange:
        try post("change", (args["staged"] as? Bool == true ? "staged " : "") + (args["path"] as? String ?? ""))
        return [text("Opened, unless `logs` says otherwise.")]
    case .logs:
        let log = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        return [text(log.split(separator: "\n").suffix(args["lines"] as? Int ?? 50).joined(separator: "\n"))]
    case .stopTestApp:
        let test = try TestCopy()
        quit(test)
        let fm = FileManager.default
        try? fm.removeItem(at: test.app)
        try? fm.removeItem(at: devDir)
        try? fm.removeItem(at: fm.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/\(test.name)"))
        _ = try? run("defaults", "delete", test.id)
        return [text("Test copy quit and removed.")]
    }
}

func running(_ test: TestCopy) -> [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: test.id) }

func quit(_ test: TestCopy) {
    running(test).forEach { $0.terminate() }
    if !wait(10, until: { running(test).isEmpty }) {  // e.g. stuck on the "sessions are busy" confirmation
        running(test).forEach { $0.forceTerminate() }
        _ = wait(5, until: { running(test).isEmpty })
    }
}

/// Asks the app for a snapshot; false if none arrived in time (e.g. the window isn't open yet).
func requestSnapshot(_ seconds: TimeInterval) throws -> Bool {
    try? FileManager.default.removeItem(at: snapshotFile)
    try post("snapshot")
    return wait(seconds, until: { FileManager.default.fileExists(atPath: snapshotFile.path) })
}

/// Asks the app to describe its panes.
func requestLayout() throws -> String {
    try? FileManager.default.removeItem(at: layoutFile)
    try post("layout")
    guard wait(5, until: { FileManager.default.fileExists(atPath: layoutFile.path) }) else {
        throw ToolError(message: "No layout arrived; is the test copy running?")
    }
    return try String(contentsOf: layoutFile, encoding: .utf8)
}

/// Sends an action to the test copy's DevHooks, which listens on its own bundle ID + ".dev".
func post(_ action: String, _ arg: String = "") throws {
    let test = try TestCopy()
    guard !running(test).isEmpty else { throw ToolError(message: "The test copy isn't running; call start_test_app.") }
    DistributedNotificationCenter.default().postNotificationName(
        .init("\(test.id).dev"), object: nil, userInfo: ["action": action, "arg": arg], deliverImmediately: true)
}

/// Runs the run loop (which updates the running-apps list) until the condition holds or time runs out.
func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return true
}

@discardableResult
func run(_ args: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = args
    process.currentDirectoryURL = repo
    process.standardInput = FileHandle.nullDevice  // stdin is the MCP message stream
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw ToolError(message: output) }
    return output
}

func text(_ string: String) -> [String: Any] { ["type": "text", "text": string] }

func send(_ message: [String: Any]) {
    var data = try! JSONSerialization.data(withJSONObject: message)
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

while let line = readLine() {
    // Messages without an id are notifications and get no reply.
    guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let id = request["id"] else { continue }
    let params = request["params"] as? [String: Any] ?? [:]
    let result: [String: Any]
    switch request["method"] as? String {
    case "initialize":
        result = ["protocolVersion": params["protocolVersion"] ?? "2025-06-18",
                  "capabilities": ["tools": [String: Any]()],
                  "serverInfo": ["name": "patchbay-dev", "version": "1.0"]]
    case "tools/list":
        result = ["tools": Tool.allCases.map(\.schema)]
    case "tools/call":
        do {
            let name = params["name"] as? String ?? ""
            guard let tool = Tool(rawValue: name) else { throw ToolError(message: "Unknown tool \(name)") }
            result = ["content": try call(tool, params["arguments"] as? [String: Any] ?? [:])]
        } catch {
            result = ["content": [text((error as? ToolError)?.message ?? "\(error)")], "isError": true]
        }
    case "ping":
        result = [:]
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
        continue
    }
    send(["jsonrpc": "2.0", "id": id, "result": result])
}
