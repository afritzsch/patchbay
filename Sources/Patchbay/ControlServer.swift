import Foundation

/// A Unix domain socket in the support folder for agents in the app's terminals. Their MCP server is
/// `patchbay-mcp.sh`, which relays the agent's stdin and stdout to it with `nc`: the first line is the session the
/// agent runs in, then JSON-RPC messages, one per line each way. The messages are answered by `handle`.
@MainActor
final class ControlServer {
    private let handle: (Data, _ caller: UUID?) async -> Data?
    private var listener: DispatchSourceRead?
    private var connections: [Connection] = []

    @MainActor
    private final class Connection {
        let file: FileHandle
        var introduced = false
        var caller: UUID?
        var buffer = Data()

        init(fd: Int32) { file = FileHandle(fileDescriptor: fd, closeOnDealloc: true) }
    }

    init(handle: @escaping (Data, _ caller: UUID?) async -> Data?) {
        self.handle = handle
        let path = ShellIntegration.controlSocket.path
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            NSLog("Patchbay: socket path too long: \(path)")
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        // Close-on-exec: the shells the app starts would otherwise inherit the socket and keep connections open.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Only this user may connect; the support folder is private as well.
        guard fd >= 0, bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            NSLog("Patchbay: control socket not opened: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.accept(fd) }
        }
        source.resume()
        listener = source
    }

    private func accept(_ listener: Int32) {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1 // Writing to an agent that has quit would otherwise kill the app with SIGPIPE.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connection = Connection(fd: fd)
        connections.append(connection)
        connection.file.readabilityHandler = { [weak self] file in
            let data = file.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data, on: connection) } }
        }
    }

    private func received(_ data: Data, on connection: Connection) {
        guard !data.isEmpty else { // The agent's MCP server ended.
            connection.file.readabilityHandler = nil
            connections.removeAll { $0 === connection }
            return
        }
        connection.buffer += data
        while let newline = connection.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = connection.buffer[connection.buffer.startIndex..<newline]
            connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
            guard connection.introduced else {
                connection.introduced = true
                connection.caller = UUID(uuidString: String(decoding: line, as: UTF8.self))
                continue
            }
            // Concurrently: a reply may wait (wait_for) while later requests are answered.
            Task {
                guard var reply = await handle(line, connection.caller) else { return }
                reply.append(UInt8(ascii: "\n"))
                try? connection.file.write(contentsOf: reply)
            }
        }
    }
}
