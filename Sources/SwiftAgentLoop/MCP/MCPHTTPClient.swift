import Foundation

// MARK: - Authorization mode

/// How an `MCPHTTPClient` authenticates its requests.
public enum MCPHTTPAuthorization: Sendable {
    /// No Authorization header (local/unprotected servers).
    case none
    /// Static token: `Authorization: Bearer <token>` on every request.
    case bearer(String)
    /// Full MCP OAuth 2.1: discovery, dynamic registration, PKCE browser flow
    /// (presented by the app), refresh. See `MCPOAuthClient`.
    case oauth(MCPOAuthClient)
}

// MARK: - MCPHTTPClient

/// MCP client over the Streamable HTTP transport: JSON-RPC messages POSTed to
/// a single endpoint; responses arrive as `application/json` or as a
/// `text/event-stream` body. Supports `Mcp-Session-Id` session management and
/// transparent re-auth (401 → OAuth flow → retry) / re-initialize (404 on an
/// expired session → new handshake → retry).
///
/// Like the stdio `MCPClient`, server-initiated requests are unsupported and
/// answered with method-not-found; server notifications are ignored.
public actor MCPHTTPClient: MCPConnection {
    public static let protocolVersion = "2025-06-18"

    private let endpoint: URL
    private let authorization: MCPHTTPAuthorization
    private let session: URLSession

    private var started = false
    private var nextID = 1
    private var sessionID: String?
    private var negotiatedProtocolVersion: String?
    private var clientName = "swift-agent-loop"
    private var clientVersion = "0.1.0"

    /// Per-request idle timeout (time between bytes, so a slowly-streaming
    /// long tool call is not cut off). MCP servers may do real I/O.
    public var requestTimeout: TimeInterval = 60

    public init(endpoint: URL, authorization: MCPHTTPAuthorization = .none, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.authorization = authorization
        // Rebuild the session around a redirect-preserving delegate:
        // URLSession strips Authorization when following redirects, so a
        // server that slash-redirects its endpoint (FastAPI /mcp → /mcp/)
        // would turn every authenticated call into a 401. The caller's
        // configuration (mock protocols, cookies, timeouts) is kept.
        self.session = URLSession(
            configuration: session.configuration,
            delegate: RedirectPreservingDelegate(),
            delegateQueue: nil
        )
    }

    // MARK: Lifecycle

    /// Perform the initialize handshake. A 401 here triggers the OAuth flow
    /// when configured, so first-ever launch can go straight to sign-in.
    public func start(clientName: String = "swift-agent-loop", clientVersion: String = "0.1.0") async throws {
        guard !started else { return }
        self.clientName = clientName
        self.clientVersion = clientVersion
        try await initializeHandshake()
        started = true
    }

    /// Best-effort session termination (HTTP DELETE), then forget local state.
    public func shutdown() async {
        if let sessionID {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "DELETE"
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            _ = try? await session.data(for: request)
        }
        sessionID = nil
        started = false
    }

    // MARK: Tools

    /// Fetch the server's tool catalog (follows `nextCursor` pagination).
    public func listTools() async throws -> [MCPToolInfo] {
        guard started else { throw MCPError.notStarted }
        var tools: [MCPToolInfo] = []
        var cursor: JSONValue?
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await request(method: "tools/list", params: .object(params))
            let page = try MCPWire.decodeToolsPage(result)
            tools.append(contentsOf: page.tools)
            cursor = page.nextCursor
        } while cursor != nil
        return tools
    }

    /// Invoke a tool. Text content parts are concatenated with newlines.
    public func callTool(_ name: String, arguments: JSONValue) async throws -> MCPCallResult {
        guard started else { throw MCPError.notStarted }
        let result = try await request(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments,
        ]))
        return try MCPWire.decodeCallResult(result)
    }

    // MARK: Handshake

    private func initializeHandshake() async throws {
        sessionID = nil
        negotiatedProtocolVersion = nil
        let result = try await request(method: "initialize", params: MCPWire.initializeParams(
            clientName: clientName,
            clientVersion: clientVersion,
            protocolVersion: Self.protocolVersion
        ))
        if case .object(let object) = result, case .string(let version)? = object["protocolVersion"] {
            negotiatedProtocolVersion = version
        }
        try await notify(method: "notifications/initialized", params: .object([:]))
    }

    // MARK: Request core

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        var envelope = JSONRPCEnvelope()
        envelope.id = id
        envelope.method = method
        envelope.params = params
        let body = try JSONEncoder().encode(envelope)

        let isInitialize = method == "initialize"
        var didAuthorize = false
        var didReinitialize = false
        while true {
            let urlRequest = try await buildRequest(body: body, afterHandshake: !isInitialize)
            do {
                return try await performExchange(urlRequest, id: id, method: method, isInitialize: isInitialize)
            } catch TransportSignal.unauthorized(let header) {
                guard case .oauth(let oauthClient) = authorization, !didAuthorize else {
                    throw MCPError.httpError(status: 401, body: header ?? "")
                }
                didAuthorize = true
                _ = try await oauthClient.authorize(resource: endpoint, wwwAuthenticate: header)
            } catch TransportSignal.sessionNotFound {
                // Server expired our session (redeploy, GC). Start a new one and
                // replay the request — once.
                guard !didReinitialize, !isInitialize, started else {
                    throw MCPError.connectionClosed
                }
                didReinitialize = true
                try await initializeHandshake()
            }
        }
    }

    private func notify(method: String, params: JSONValue) async throws {
        var envelope = JSONRPCEnvelope()
        envelope.method = method
        envelope.params = params
        let body = try JSONEncoder().encode(envelope)
        let urlRequest = try await buildRequest(body: body, afterHandshake: true)
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.protocolError("\(method): non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw MCPError.httpError(status: http.statusCode, body: String(data: data.prefix(2048), encoding: .utf8) ?? "")
        }
    }

    private func buildRequest(body: Data, afterHandshake: Bool) async throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if afterHandshake {
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            request.setValue(negotiatedProtocolVersion ?? Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let header = try await authorizationHeader() {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func authorizationHeader() async throws -> String? {
        switch authorization {
        case .none:
            return nil
        case .bearer(let token):
            return "Bearer \(token)"
        case .oauth(let client):
            // nil = no usable token; go unauthenticated and let the 401 path
            // run the interactive flow.
            return try await client.validAccessToken(resource: endpoint).map { "Bearer \($0)" }
        }
    }

    // MARK: Response handling

    private func performExchange(
        _ urlRequest: URLRequest,
        id: Int,
        method: String,
        isInitialize: Bool
    ) async throws -> JSONValue {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw MCPError.timedOut(method: method)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.protocolError("\(method): non-HTTP response")
        }

        switch http.statusCode {
        case 401:
            throw TransportSignal.unauthorized(http.value(forHTTPHeaderField: "WWW-Authenticate"))
        case 404 where sessionID != nil:
            throw TransportSignal.sessionNotFound
        case 202, 204:
            return .null
        case 200...299:
            break
        default:
            let body = await Self.collectBody(bytes, limit: 2048)
            throw MCPError.httpError(status: http.statusCode, body: String(data: body, encoding: .utf8) ?? "")
        }

        if isInitialize, let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionID = sid
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.hasPrefix("text/event-stream") {
            return try await readSSEResponse(bytes, id: id, method: method)
        }
        let data = await Self.collectBody(bytes, limit: nil)
        guard let envelope = try? JSONDecoder().decode(JSONRPCEnvelope.self, from: data) else {
            throw MCPError.protocolError("\(method): undecodable response body")
        }
        if let error = envelope.error {
            throw MCPError.serverError(code: error.code, message: error.message)
        }
        return envelope.result ?? .null
    }

    /// Read an SSE body until the response with our id arrives. Other messages
    /// on the stream — notifications, unrelated ids — are skipped; server
    /// requests get a method-not-found reply POSTed back (fire-and-forget).
    private func readSSEResponse(
        _ bytes: URLSession.AsyncBytes,
        id: Int,
        method: String
    ) async throws -> JSONValue {
        let dataPrefix = Array("data:".utf8)
        var lineBuffer: [UInt8] = []
        var dataLines: [String] = []

        func envelopeFromEvent() -> JSONRPCEnvelope? {
            guard !dataLines.isEmpty else { return nil }
            let payload = dataLines.joined(separator: "\n")
            dataLines = []
            return try? JSONDecoder().decode(JSONRPCEnvelope.self, from: Data(payload.utf8))
        }

        func handle(_ envelope: JSONRPCEnvelope) throws -> JSONValue? {
            if envelope.id == id, envelope.method == nil {
                if let error = envelope.error {
                    throw MCPError.serverError(code: error.code, message: error.message)
                }
                return envelope.result ?? .null
            }
            if let requestID = envelope.id, envelope.method != nil {
                replyMethodNotFound(id: requestID)
            }
            return nil
        }

        // Line splitting on \n with a trailing-\r strip covers LF and CRLF —
        // CR-only SSE framing does not occur in practice.
        for try await byte in bytes {
            guard byte == 0x0A else {
                lineBuffer.append(byte)
                continue
            }
            var line = lineBuffer
            lineBuffer = []
            if line.last == 0x0D { line.removeLast() }
            if line.isEmpty {
                if let envelope = envelopeFromEvent(), let result = try handle(envelope) { return result }
            } else if line.starts(with: dataPrefix) {
                var value = Array(line.dropFirst(dataPrefix.count))
                if value.first == 0x20 { value.removeFirst() }
                dataLines.append(String(bytes: value, encoding: .utf8) ?? "")
            }
            // event:/id:/retry: fields and comments are ignored — MCP carries
            // the JSON-RPC message entirely in data.
        }
        // Flush a trailing event that ended with the stream instead of a blank line.
        if let envelope = envelopeFromEvent(), let result = try handle(envelope) { return result }
        throw MCPError.connectionClosed
    }

    private func replyMethodNotFound(id: Int) {
        var reply = JSONRPCEnvelope()
        reply.id = id
        reply.error = JSONRPCErrorObject(code: -32601, message: "Method not supported")
        guard let body = try? JSONEncoder().encode(reply) else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let request = try? await self.buildRequest(body: body, afterHandshake: true) else { return }
            _ = try? await self.sendAndForget(request)
        }
    }

    private func sendAndForget(_ request: URLRequest) async throws {
        _ = try await session.data(for: request)
    }

    private static func collectBody(_ bytes: URLSession.AsyncBytes, limit: Int?) async -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if let limit, data.count >= limit { break }
            }
        } catch {
            // Partial body is fine for error reporting.
        }
        return data
    }
}

// MARK: - Internal transport signals

/// Conditions the request loop reacts to (re-auth, re-initialize) rather than
/// surfacing directly.
private enum TransportSignal: Error {
    case unauthorized(String?)
    case sessionNotFound
}

// MARK: - Redirect handling

/// Re-attaches the original request's Authorization header when a redirect
/// stays on the same scheme+host. Cross-origin redirects keep URLSession's
/// default behavior (header stripped) — never leak tokens to another host.
private final class RedirectPreservingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        var request = request
        if request.value(forHTTPHeaderField: "Authorization") == nil,
           let original = task.originalRequest,
           let authorization = original.value(forHTTPHeaderField: "Authorization"),
           original.url?.host == request.url?.host,
           original.url?.scheme == request.url?.scheme {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        completionHandler(request)
    }
}
