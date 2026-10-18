import Foundation
import Synchronization

/// A language server Patchbay can start for the editor: which files it handles and the command that runs it.
struct LanguageServerConfig: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    /// A shell command line, run with the PATH of the user's login shell.
    var command: String
    /// File extensions without the dot, or whole file names.
    var extensions: [String]

    static let builtIn = [
        LanguageServerConfig(id: "swift", name: "Swift", command: "xcrun sourcekit-lsp",
                             extensions: ["swift", "c", "h", "m", "mm", "cc", "cpp", "hpp"]),
        LanguageServerConfig(id: "typescript", name: "TypeScript", command: "typescript-language-server --stdio",
                             extensions: ["ts", "tsx", "js", "jsx", "mjs", "cjs"]),
        LanguageServerConfig(id: "python", name: "Python", command: "pyright-langserver --stdio", extensions: ["py", "pyi"]),
        LanguageServerConfig(id: "go", name: "Go", command: "gopls", extensions: ["go"]),
        LanguageServerConfig(id: "rust", name: "Rust", command: "rust-analyzer", extensions: ["rs"]),
    ]

    /// Servers added in Settings, stored as JSON in UserDefaults. They come before the built-in ones.
    static var custom: [LanguageServerConfig] {
        get { savedCustom.withLock { $0 } }
        set {
            savedCustom.withLock { $0 = newValue }
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Preferences.Keys.customLanguageServers)
        }
    }

    private static let savedCustom = Mutex(UserDefaults.standard.data(forKey: Preferences.Keys.customLanguageServers)
        .flatMap { try? JSONDecoder().decode([LanguageServerConfig].self, from: $0) } ?? [])

    static func forFile(_ path: String) -> LanguageServerConfig? {
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension.lowercased()
        return (custom + builtIn).first { !$0.command.isEmpty && ($0.extensions.contains(ext) || $0.extensions.contains(file)) }
    }

    /// The LSP language identifier for a file.
    static func languageID(of path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["ts": "typescript", "tsx": "typescriptreact", "js": "javascript", "jsx": "javascriptreact",
                "mjs": "javascript", "cjs": "javascript", "py": "python", "pyi": "python", "rs": "rust",
                "h": "c", "m": "objective-c", "mm": "objective-cpp", "cc": "cpp", "hpp": "cpp"][ext] ?? ext
    }
}

/// The parts of the Language Server Protocol the editor uses.
enum LSP {
    /// Lines and UTF-16 code units, both from 0: the same units as NSString.
    struct Position: Codable, Hashable, Sendable {
        var line: Int
        var character: Int
    }

    struct Range: Codable, Hashable, Sendable {
        var start: Position
        var end: Position
    }

    struct Location: Decodable, Sendable {
        var uri: String
        var range: Range
    }

    struct Diagnostic: Decodable, Hashable, Sendable {
        var range: Range
        /// 1 error, 2 warning, 3 information, 4 hint.
        var severity: Int?
        var message: String
        var isError: Bool { (severity ?? 1) == 1 }
    }

    struct CompletionItem: Decodable, Sendable {
        struct Edit: Decodable, Sendable { var newText: String }
        var label: String
        var sortText: String?
        var insertText: String?
        var textEdit: Edit?
        var text: String { textEdit?.newText ?? insertText ?? label }
    }

    /// A completion answer: a list with `items`, a bare array, or nothing.
    struct Completions: Decodable, Sendable {
        var items: [CompletionItem]
        private enum Keys: CodingKey { case items }

        init(from decoder: Decoder) throws {
            if let list = try? decoder.container(keyedBy: Keys.self) {
                items = try list.decode([CompletionItem].self, forKey: .items)
            } else {
                items = try decoder.singleValueContainer().decode([CompletionItem].self)
            }
        }
    }

    /// A hover answer's text, whichever of the protocol's shapes it came in.
    struct Hover: Decodable, Sendable {
        var text: String
        private enum Keys: CodingKey { case contents, value }

        init(from decoder: Decoder) throws {
            let contents = try decoder.container(keyedBy: Keys.self).superDecoder(forKey: .contents)
            func string(_ decoder: Decoder) throws -> String { // "text", or {kind or language, value}
                if let text = try? decoder.singleValueContainer().decode(String.self) { return text }
                return try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .value)
            }
            if var array = try? contents.unkeyedContainer() {
                var parts: [String] = []
                while !array.isAtEnd { parts.append(try string(array.superDecoder())) }
                text = parts.joined(separator: "\n")
            } else {
                text = try string(contents)
            }
        }

        /// The first line of code, e.g. `struct Syntax`, or else of text: markdown fences dropped.
        var summary: String? {
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if let fence = lines.firstIndex(where: { $0.hasPrefix("```") }), fence + 1 < lines.count,
               !lines[fence + 1].hasPrefix("```") {
                return lines[fence + 1]
            }
            return lines.first { !$0.isEmpty && !$0.hasPrefix("```") }
        }
    }

    /// A definition answer: one location, several, or location links.
    struct Definition: Decodable, Sendable {
        var locations: [Location]
        private struct Link: Decodable { var targetUri: String; var targetSelectionRange: Range }

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let one = try? value.decode(Location.self) {
                locations = [one]
            } else if let many = try? value.decode([Location].self) {
                locations = many
            } else {
                locations = try value.decode([Link].self).map { Location(uri: $0.targetUri, range: $0.targetSelectionRange) }
            }
        }
    }

    static func position(at location: Int, in text: NSString) -> Position {
        let location = min(max(location, 0), text.length)
        var (line, start) = (0, 0)
        while true { // past the end of each line, newline included, is the next one
            let end = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            guard end > start, end <= location else { break }
            (line, start) = (line + 1, end)
        }
        return Position(line: line, character: location - start)
    }

    /// The UTF-16 offset of `position`, kept inside the text and the line: servers send ranges for text that has
    /// changed since, and sourcekit-lsp crashes on positions past a line's end.
    static func location(of position: Position, in text: NSString) -> Int {
        var start = 0
        for _ in 0..<max(position.line, 0) {
            let next = NSMaxRange(text.lineRange(for: NSRange(location: start, length: 0)))
            if next == start || next > text.length { break }
            start = next
        }
        let line = text.lineRange(for: NSRange(location: min(start, text.length), length: 0))
        var contentsEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: line)
        return min(start + max(position.character, 0), max(contentsEnd, start))
    }

    /// Takes the complete messages off the front of `buffer`. Each is headers (`Content-Length: N`), a blank
    /// line, then N bytes of JSON; whatever follows the last complete one stays in the buffer.
    static func takeMessages(from buffer: inout Data) -> [Data] {
        var messages: [Data] = []
        let separator = Data("\r\n\r\n".utf8)
        while let end = buffer.range(of: separator) {
            let headers = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            let length = headers.split(separator: "\r\n").lazy
                .compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }.first ?? 0
            guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(end.upperBound, offsetBy: length)
            messages.append(Data(buffer[end.upperBound..<bodyEnd]))
            buffer = Data(buffer[bodyEnd...])
        }
        return messages
    }

    static func frame(_ message: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }
}

/// One running language server for one repository, talking JSON-RPC over the process's stdin and stdout.
/// Notifications sent before the server is initialized wait in a queue, so they arrive in order.
@MainActor @Observable final class LanguageServer {
    enum State: Equatable {
        case starting, ready, stopped
        case failed(String)
    }

    let config: LanguageServerConfig
    let root: String
    private(set) var state = State.starting
    /// By file path, as the server last published them.
    private(set) var diagnostics: [String: [LSP.Diagnostic]] = [:]
    /// What the server reports doing ("Indexing"), by progress token.
    private(set) var activity: [String: String] = [:]

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private let writer = DispatchQueue(label: "LanguageServer.writer")
    @ObservationIgnored private var queued: [Data] = []
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    /// The text each open document was last sent with, and its version.
    @ObservationIgnored private var documents: [String: (text: String, version: Int)] = [:]
    @ObservationIgnored var openDocuments: Int { documents.count }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    init(config: LanguageServerConfig, root: String) {
        self.config = config
        self.root = root
    }

    func start() {
        Task {
            let path = await inBackground { LanguageServer.userPath }
            do {
                try launch(path: path)
                let rootURI = URL(filePath: root).absoluteString
                _ = try await send(request: "initialize", [
                    "processId": ProcessInfo.processInfo.processIdentifier,
                    "rootUri": rootURI,
                    "workspaceFolders": [["uri": rootURI, "name": (root as NSString).lastPathComponent]],
                    "capabilities": [
                        "general": ["positionEncodings": ["utf-16"]],
                        "window": ["workDoneProgress": true],
                        "textDocument": [
                            "synchronization": ["didSave": true],
                            "publishDiagnostics": [:],
                            "completion": ["completionItem": ["snippetSupport": false]],
                            "hover": ["contentFormat": ["plaintext", "markdown"]],
                            "definition": ["linkSupport": true],
                        ],
                    ] as [String: Any],
                ], early: true)
                notify("initialized", [:], early: true)
                guard state == .starting else { return }
                state = .ready
                for message in queued { write(message) }
                queued = []
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Sends a document's current text: opens it the first time, then sends it whole when it changed.
    func sync(_ url: URL, text: String) {
        guard state == .starting || state == .ready else { return }
        let uri = url.absoluteString
        if let document = documents[uri] {
            guard document.text != text else { return }
            documents[uri] = (text, document.version + 1)
            notify("textDocument/didChange", ["textDocument": ["uri": uri, "version": document.version + 1],
                                               "contentChanges": [["text": text]]])
        } else {
            documents[uri] = (text, 1)
            notify("textDocument/didOpen", ["textDocument": ["uri": uri, "languageId": LanguageServerConfig.languageID(of: url.path),
                                                             "version": 1, "text": text]])
        }
    }

    func saved(_ url: URL) {
        if documents[url.absoluteString] != nil { notify("textDocument/didSave", ["textDocument": ["uri": url.absoluteString]]) }
    }

    func close(_ url: URL) {
        guard documents.removeValue(forKey: url.absoluteString) != nil else { return }
        notify("textDocument/didClose", ["textDocument": ["uri": url.absoluteString]])
        diagnostics[url.path] = nil
    }

    func completions(_ url: URL, at position: LSP.Position) async -> [LSP.CompletionItem] {
        (try? await request("textDocument/completion", at: position, in: url, as: LSP.Completions.self))?.items ?? []
    }

    func hover(_ url: URL, at position: LSP.Position) async -> LSP.Hover? {
        try? await request("textDocument/hover", at: position, in: url, as: LSP.Hover.self)
    }

    func definition(_ url: URL, at position: LSP.Position) async -> LSP.Location? {
        (try? await request("textDocument/definition", at: position, in: url, as: LSP.Definition.self))?.locations.first
    }

    /// Asks the server to quit, and makes sure it does.
    func stop() {
        guard let process, process.isRunning else { return }
        state = .stopped
        if input != nil {
            Task { _ = try? await send(request: "shutdown", nil, early: true) }
            notify("exit", nil, early: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if process.isRunning { process.terminate() } }
    }

    /// For quitting the app: there is no time to ask.
    func terminate() {
        state = .stopped
        process?.terminate()
    }

    // MARK: - Messages

    private func request<R: Decodable>(_ method: String, at position: LSP.Position, in url: URL, as type: R.Type) async throws -> R? {
        let result = try await send(request: method, ["textDocument": ["uri": url.absoluteString],
                                                      "position": ["line": position.line, "character": position.character]])
        return result == Data("null".utf8) ? nil : try JSONDecoder().decode(R.self, from: result)
    }

    /// Sends a request and waits for its result as JSON (`null` for none). Cancelling the task cancels the request.
    private func send(request method: String, _ params: Any?, early: Bool = false) async throws -> Data {
        let id = nextID
        nextID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
                message["params"] = params
                send(message, early: early)
            }
        } onCancel: {
            Task { @MainActor in self.notify("$/cancelRequest", ["id": id]) }
        }
    }

    private func notify(_ method: String, _ params: Any?, early: Bool = false) {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        message["params"] = params
        send(message, early: early)
    }

    private func send(_ message: [String: Any], early: Bool) {
        let data = LSP.frame(message)
        if state == .ready || early { write(data) } else { queued.append(data) }
    }

    private func write(_ data: Data) {
        guard let input else { return }
        // Off the main thread: a busy server can leave the pipe full.
        writer.async { try? input.write(contentsOf: data) }
    }

    private func handle(_ data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let method = message["method"] as? String
        if let id = message["id"] as? Int, method == nil {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: Failure(errorDescription: error["message"] as? String ?? "Request failed"))
            } else {
                let result = try? JSONSerialization.data(withJSONObject: message["result"] ?? NSNull(), options: .fragmentsAllowed)
                continuation.resume(returning: result ?? Data("null".utf8))
            }
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        if let id = message["id"] {
            // A request to the client (progress tokens, registrations, settings): accept it without doing anything.
            let items = (params["items"] as? [Any])?.map { _ in NSNull() }
            write(LSP.frame(["jsonrpc": "2.0", "id": id, "result": method == "workspace/configuration" ? items ?? [] : NSNull()]))
            return
        }
        switch method {
        case "textDocument/publishDiagnostics":
            guard let uri = params["uri"] as? String, let path = URL(string: uri)?.path,
                  let data = try? JSONSerialization.data(withJSONObject: params["diagnostics"] ?? []),
                  let list = try? JSONDecoder().decode([LSP.Diagnostic].self, from: data) else { return }
            diagnostics[path] = list
        case "$/progress":
            guard let token = params["token"].map({ "\($0)" }), let value = params["value"] as? [String: Any] else { return }
            switch value["kind"] as? String {
            case "begin": activity[token] = value["title"] as? String ?? "Working"
            case "end": activity[token] = nil
            default: break
            }
        default:
            break
        }
    }

    // MARK: - Process

    private func launch(path: String) throws {
        let process = Process()
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "exec " + config.command]
        process.currentDirectoryURL = URL(filePath: root)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Writing to a server that has quit would otherwise kill the app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        nonisolated(unsafe) var buffer = Data() // only the reading handler touches it, one call at a time
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            buffer.append(chunk)
            let messages = LSP.takeMessages(from: &buffer)
            guard !messages.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { for message in messages { self?.handle(message) } } }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.state != .stopped else { return }
                    let name = self.config.command.split(separator: " ").first.map(String.init) ?? self.config.command
                    self.fail(status == 127 ? "\(name) isn't installed" : "\(self.config.name) language server quit (\(status))")
                }
            }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
    }

    private func fail(_ message: String) {
        state = .failed(message)
        input = nil
        queued = []
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(throwing: Failure(errorDescription: message)) }
    }

    /// The PATH of the user's login shell: apps started from the Finder get a minimal one, without Homebrew or
    /// npm's folders where language servers live. Blocking; read off the main thread.
    nonisolated static let userPath: String = {
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: ShellIntegration.userShell)
        // Interactive too: nvm and the like set PATH in .zshrc. The marker skips whatever the startup files print.
        process.arguments = ["-ilc", "printf '\\n__PATH__%s\\n' \"$PATH\""]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return fallback }
        let kill = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: kill)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        kill.cancel()
        let path = output.split(separator: "\n").last { $0.hasPrefix("__PATH__") }?.dropFirst(8)
        return path.map(String.init).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }()
}

/// The running servers, one per repository and language, started when an editor needs one.
@MainActor final class LanguageServers {
    private var servers: [String: LanguageServer] = [:]
    private var lastUsed: [String: Date] = [:]
    /// Each takes a few hundred MB; past this many, idle ones are stopped.
    private let limit = 3

    /// The server for a file in a repository, nil when there is none for its language or they are turned off.
    func server(for path: String, root: String) -> LanguageServer? {
        guard UserDefaults.standard.bool(forKey: Preferences.Keys.languageServers),
              let config = LanguageServerConfig.forFile(path) else { return nil }
        let key = config.id + "\0" + root
        lastUsed[key] = .now
        if let server = servers[key], server.config == config, server.state == .starting || server.state == .ready {
            return server
        }
        servers[key]?.stop()
        let idle = servers.filter { $0.value.openDocuments == 0 }.keys.sorted { lastUsed[$0] ?? .distantPast < lastUsed[$1] ?? .distantPast }
        for old in idle.prefix(max(servers.count + 1 - limit, 0)) { remove(old) }
        let server = LanguageServer(config: config, root: root)
        servers[key] = server
        server.start()
        return server
    }

    /// Called when an editor closes: a server nobody has used for a while is stopped.
    func release(_ server: LanguageServer) {
        let key = server.config.id + "\0" + server.root
        lastUsed[key] = .now
        Task {
            try? await Task.sleep(for: .seconds(300))
            if servers[key] === server, server.openDocuments == 0, let last = lastUsed[key], -last.timeIntervalSinceNow >= 299 {
                remove(key)
            }
        }
    }

    func terminateAll() {
        for server in servers.values { server.terminate() }
        servers = [:]
    }

    private func remove(_ key: String) {
        servers.removeValue(forKey: key)?.stop()
        lastUsed[key] = nil
    }
}
