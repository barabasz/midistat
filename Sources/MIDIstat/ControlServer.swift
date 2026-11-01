import Foundation

/// Local control channel: the running app listens on a Unix domain socket in
/// ~/Library/Application Support/MIDIstat (directory 0700, socket 0600, so
/// only the same user can connect). The app binary doubles as the client:
///
///     MIDIstat ctl <command> [arguments]
///
/// Protocol: the client sends one line of text, the app replies with JSON
/// and closes the connection.
enum ControlChannel {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MIDIstat", isDirectory: true)
    }

    static var socketPath: String { directory.appendingPathComponent("control.sock").path }

    fileprivate static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    fileprivate static func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// Reads until a newline or EOF (requests are one line, responses end with EOF).
    fileprivate static func read(_ fd: Int32, stopAtNewline: Bool, limit: Int = 4 << 20) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if stopAtNewline, buffer[0..<count].contains(UInt8(ascii: "\n")) { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    fileprivate static func write(_ fd: Int32, _ string: String) {
        var bytes = Array(string.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written <= 0 { return }
            bytes = bytes.dropFirst(written)
        }
    }
}

/// Runs in the app. Requests are handled on the main thread, so the handler
/// can use AppKit and the app's state directly.
final class ControlServer {
    private let handler: (String) -> String
    private let backgroundHandler: (String) -> String?
    private var listener: Int32 = -1

    /// `backgroundHandler` runs first, on the server thread, for slow commands
    /// that must not block the UI (e.g. network requests); nil means "not mine".
    init(handler: @escaping (String) -> String, backgroundHandler: @escaping (String) -> String? = { _ in nil }) {
        self.handler = handler
        self.backgroundHandler = backgroundHandler
    }

    func start() throws {
        let path = ControlChannel.socketPath
        try FileManager.default.createDirectory(at: ControlChannel.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)  // a stale socket from a previous run

        guard var address = ControlChannel.address(path) else { throw POSIXError(.ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let bound = ControlChannel.withSockaddr(&address) { bind(fd, $0, $1) }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        listener = fd

        let thread = Thread { [handler, backgroundHandler] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return  // listener closed
                }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                let request = ControlChannel.read(client, stopAtNewline: true)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let response = backgroundHandler(request) ?? DispatchQueue.main.sync { handler(request) }
                ControlChannel.write(client, response + "\n")
                close(client)
            }
        }
        thread.name = "MIDIstat control"
        thread.start()
    }

    func stop() {
        guard listener >= 0 else { return }
        close(listener)
        listener = -1
        unlink(ControlChannel.socketPath)
    }
}

/// Runs as `MIDIstat ctl …`: sends the command to the running app and prints the reply.
enum ControlClient {
    /// Exit codes: 0 = ok, 1 = the app reported an error, 2 = the app is not running.
    static func run(_ arguments: [String]) -> Int32 {
        let command = arguments.isEmpty ? "help" : arguments.joined(separator: " ")
        guard var address = ControlChannel.address(ControlChannel.socketPath) else { return 2 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return 2 }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        guard ControlChannel.withSockaddr(&address, { connect(fd, $0, $1) }) == 0 else {
            FileHandle.standardError.write(Data("MIDIstat is not running (no control socket at \(ControlChannel.socketPath)).\n".utf8))
            return 2
        }
        ControlChannel.write(fd, command + "\n")
        shutdown(fd, SHUT_WR)
        let reply = ControlChannel.read(fd, stopAtNewline: false)
        print(reply, terminator: reply.hasSuffix("\n") ? "" : "\n")

        let ok = (try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])?["ok"] as? Bool
        return ok == true ? 0 : 1
    }
}
