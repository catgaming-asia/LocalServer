import Foundation
import Network

/// Minimal static file server: GET/HEAD, one request per connection, no directory listings.
final class HTTPServer {
    struct LogEntry {
        let method: String
        let path: String
        let status: Int
        let bytes: Int
    }

    private let queue = DispatchQueue(label: "LocalServer.http")
    private var listener: NWListener?
    private let router: Router
    private let onLog: (LogEntry) -> Void
    private let onState: (String?) -> Void

    /// onState receives nil when listening, or an error message when the listener fails.
    init(router: Router, onLog: @escaping (LogEntry) -> Void, onState: @escaping (String?) -> Void) {
        self.router = router
        self.onLog = onLog
        self.onState = onState
    }

    func start(port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NSError(domain: "LocalServer", code: 1) }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState(nil)
            case .failed(let error): self?.onState(error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection, buffer: Data())
    }

    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, header: buffer.subdata(in: buffer.startIndex..<end.lowerBound))
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveHeader(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, header: Data) {
        let requestLine = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ").map(String.init)
        let method = parts.first ?? "?"
        let path = parts.count > 1 ? parts[1] : "/"

        guard method == "GET" || method == "HEAD" else {
            send(connection, status: 405, reason: "Method Not Allowed", contentType: "text/plain", body: Data("405\n".utf8), headOnly: false)
            onLog(LogEntry(method: method, path: path, status: 405, bytes: 0))
            return
        }

        guard let file = router.file(for: path), let body = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            send(connection, status: 404, reason: "Not Found", contentType: "text/plain", body: Data("404\n".utf8), headOnly: method == "HEAD")
            onLog(LogEntry(method: method, path: path, status: 404, bytes: 0))
            return
        }

        send(connection, status: 200, reason: "OK", contentType: Router.contentType(for: file), body: body, headOnly: method == "HEAD")
        onLog(LogEntry(method: method, path: path, status: 200, bytes: body.count))
    }

    private func send(_ connection: NWConnection, status: Int, reason: String, contentType: String, body: Data, headOnly: Bool) {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        if !headOnly { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}
