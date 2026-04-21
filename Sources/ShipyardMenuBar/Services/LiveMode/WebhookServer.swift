import Foundation
import Network

/// Minimal HTTP/1.1 server for GitHub webhook deliveries.
///
/// Uses `Network.framework`'s `NWListener` so we don't have to bundle
/// SwiftNIO or any other SPM dependency for a single POST endpoint.
/// Parses one request/response pair per connection (closes after each
/// so we don't need full keep-alive state machinery) — webhook senders
/// reconnect per delivery anyway.
///
/// Tailscale Funnel terminates TLS at its edge and forwards plain HTTP
/// to localhost, so this server is HTTP-only. It binds to `127.0.0.1`
/// for defense in depth against accidental exposure.
final class WebhookServer {

    typealias DeliveryHandler = (_ headers: [String: String], _ body: Data) -> HTTPResponse

    struct HTTPResponse {
        let status: Int
        let body: String

        static let ok = HTTPResponse(status: 200, body: "ok\n")
        static let unauthorized = HTTPResponse(status: 401, body: "bad signature\n")
        static let notFound = HTTPResponse(status: 404, body: "not found\n")
        static let methodNotAllowed = HTTPResponse(status: 405, body: "method not allowed\n")
        static let badRequest = HTTPResponse(status: 400, body: "bad request\n")
    }

    private var listener: NWListener?
    private let handler: DeliveryHandler
    private let queue = DispatchQueue(label: "shipyard.webhook.server")

    init(handler: @escaping DeliveryHandler) {
        self.handler = handler
    }

    /// Bind to a random high port on `127.0.0.1`. Returns the bound
    /// port on success.
    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        // Loopback only — Tailscale reaches us through this same
        // loopback interface after its daemon proxies in.
        params.requiredInterfaceType = .loopback
        params.acceptLocalOnly = true

        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: queue)

        // Spin briefly until the port resolves. NWListener's `port`
        // is nil before the listener actually binds.
        let start = Date()
        while listener.port == nil {
            if Date().timeIntervalSince(start) > 2 {
                throw NSError(
                    domain: "WebhookServer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "listener didn't bind within 2s"]
                )
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return listener.port!.rawValue
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    /// Incremental receive loop — keeps pulling bytes until we have a
    /// complete HTTP/1.1 request (headers + Content-Length bytes of
    /// body). Imposes a 5 MB cap so malformed clients can't OOM us.
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.count > 5 * 1024 * 1024 {
                self.reply(connection, response: .badRequest)
                return
            }
            if let parsed = HTTPRequestParser.tryParse(buffer) {
                let response = self.route(parsed)
                self.reply(connection, response: response)
                return
            }
            if let error {
                connection.cancel()
                _ = error
                return
            }
            if isComplete {
                self.reply(connection, response: .badRequest)
                return
            }
            self.receive(connection, accumulated: buffer)
        }
    }

    private func route(_ req: HTTPRequestParser.ParsedRequest) -> HTTPResponse {
        guard req.path == "/webhook" else { return .notFound }
        guard req.method == "POST" else { return .methodNotAllowed }
        return handler(req.headers, req.body)
    }

    private func reply(_ connection: NWConnection, response: HTTPResponse) {
        let phrase: String
        switch response.status {
        case 200: phrase = "OK"
        case 400: phrase = "Bad Request"
        case 401: phrase = "Unauthorized"
        case 404: phrase = "Not Found"
        case 405: phrase = "Method Not Allowed"
        default:  phrase = "Error"
        }
        let bodyBytes = response.body.data(using: .utf8) ?? Data()
        var out = Data()
        out.append("HTTP/1.1 \(response.status) \(phrase)\r\n".data(using: .utf8)!)
        out.append("Content-Type: text/plain; charset=utf-8\r\n".data(using: .utf8)!)
        out.append("Content-Length: \(bodyBytes.count)\r\n".data(using: .utf8)!)
        out.append("Connection: close\r\n\r\n".data(using: .utf8)!)
        out.append(bodyBytes)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Small, defensive HTTP/1.1 request parser. Not a full implementation —
/// just enough to pull method/path and a Content-Length body out of
/// the raw bytes. Headers are lowercased for case-insensitive lookup.
enum HTTPRequestParser {
    struct ParsedRequest {
        let method: String
        let path: String
        let headers: [String: String]   // keys lowercased
        let body: Data
    }

    static func tryParse(_ data: Data) -> ParsedRequest? {
        // Headers end at the first CRLF CRLF.
        let marker: [UInt8] = [0x0d, 0x0a, 0x0d, 0x0a]
        guard let range = data.range(of: Data(marker)) else { return nil }
        let headerData = data.subdata(in: 0..<range.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0]
        let path = parts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.contains(":") {
            if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].lowercased()
                let v = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                headers[String(k)] = v
            }
        }

        let bodyStart = range.upperBound
        var body = data.subdata(in: bodyStart..<data.count)
        if let lenStr = headers["content-length"], let contentLen = Int(lenStr) {
            if body.count < contentLen { return nil }      // more to come
            if body.count > contentLen {
                body = body.subdata(in: 0..<contentLen)
            }
        }
        return ParsedRequest(
            method: method,
            path: path,
            headers: headers,
            body: body
        )
    }
}
