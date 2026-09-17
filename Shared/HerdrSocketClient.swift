import Foundation

/// Errors from the herdr socket API.
enum HerdrSocketError: Error, CustomStringConvertible {
    case connectFailed(path: String, errno: Int32)
    case writeFailed
    case closed
    case server(code: String, message: String)
    case malformedResponse(String)

    var description: String {
        switch self {
        case .connectFailed(let path, let err):
            return "cannot connect to herdr socket \(path): \(String(cString: strerror(err)))"
        case .writeFailed: return "write to herdr socket failed"
        case .closed: return "herdr socket closed"
        case .server(let code, let message): return "herdr error \(code): \(message)"
        case .malformedResponse(let line): return "malformed herdr response: \(line.prefix(200))"
        }
    }
}

/// A line-oriented connection to herdr's newline-delimited JSON socket.
final class HerdrSocketConnection {
    private let fd: Int32
    private var buffer = Data()

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrSocketError.connectFailed(path: path, errno: errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw HerdrSocketError.connectFailed(path: path, errno: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard result == 0 else {
            let err = errno
            close(fd)
            throw HerdrSocketError.connectFailed(path: path, errno: err)
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        let written = data.withUnsafeBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return -1 }
                offset += n
            }
            return offset
        }
        guard written == data.count else { throw HerdrSocketError.writeFailed }
    }

    /// Blocks until one full line arrives.
    func readLine() throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw HerdrSocketError.closed }
            buffer.append(chunk, count: n)
        }
    }

    func shutdownNow() {
        shutdown(fd, SHUT_RDWR)
    }
}

/// Request/response access to the herdr socket API. Each call opens a short
/// connection, which keeps the client stateless and thread-safe.
struct HerdrClient {
    let socketPath: String

    /// Socket for a named herdr session (`~/.config/herdr/sessions/<name>/herdr.sock`).
    static func socketPath(session: String?, home: String = NSHomeDirectory()) -> String {
        let base = home + "/.config/herdr"
        guard let session, !session.isEmpty else { return base + "/herdr.sock" }
        return base + "/sessions/\(session)/herdr.sock"
    }

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let connection = try HerdrSocketConnection(path: socketPath)
        let id = "herd-\(UUID().uuidString.prefix(8))"
        try connection.send(["id": id, "method": method, "params": params])
        let line = try connection.readLine()
        return try Self.parseResponse(line)
    }

    static func parseResponse(_ line: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw HerdrSocketError.malformedResponse(String(decoding: line, as: UTF8.self))
        }
        if let error = object["error"] as? [String: Any] {
            throw HerdrSocketError.server(
                code: error["code"] as? String ?? "unknown",
                message: error["message"] as? String ?? ""
            )
        }
        guard let result = object["result"] as? [String: Any] else {
            throw HerdrSocketError.malformedResponse(String(decoding: line, as: UTF8.self))
        }
        return result
    }

    func snapshot() throws -> HerdrSnapshot {
        let result = try call("session.snapshot")
        guard let raw = result["snapshot"] else {
            throw HerdrSocketError.malformedResponse("session.snapshot without snapshot")
        }
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(HerdrSnapshot.self, from: data)
    }

    /// Event types Herd listens to; any of them triggers a snapshot refresh.
    static let subscribedEvents = [
        "workspace.created", "workspace.updated", "workspace.renamed", "workspace.moved",
        "workspace.reordered", "workspace.closed", "workspace.focused",
        "tab.created", "tab.closed", "tab.focused", "tab.renamed", "tab.moved",
        "pane.created", "pane.updated", "pane.closed", "pane.focused", "pane.moved",
        "pane.exited", "pane.agent_detected", "layout.updated",
        // pane.agent_status_changed requires a pane_id; agent state is picked
        // up by HerdrStore's periodic refresh instead.
    ]

    /// Opens a subscription and calls `onEvent` with each pushed event's type
    /// until the connection closes or `connection.shutdownNow()` is called.
    func subscribe(
        connectionCreated: (HerdrSocketConnection) -> Void,
        onEvent: (String) -> Void
    ) throws {
        let connection = try HerdrSocketConnection(path: socketPath)
        try connection.send([
            "id": "herd-events",
            "method": "events.subscribe",
            "params": ["subscriptions": Self.subscribedEvents.map { ["type": $0] }],
        ])
        _ = try Self.parseResponse(try connection.readLine())
        connectionCreated(connection)
        while true {
            let line = try connection.readLine()
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let type = (object["event"] as? String)
                ?? (object["type"] as? String)
                ?? ((object["result"] as? [String: Any])?["type"] as? String)
                ?? "event"
            onEvent(type)
        }
    }
}
