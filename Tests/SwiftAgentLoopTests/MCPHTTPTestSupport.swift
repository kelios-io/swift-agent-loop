import Foundation
@testable import SwiftAgentLoop

// MARK: - Shared HTTP mocking for MCP transport/OAuth tests

/// URLProtocol stub routed by host, so parallel tests never collide: each test
/// registers a unique fake host and gets its own handler.
final class MockHTTP: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    private static func handler(for host: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return handler(for: host) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let handler = Self.handler(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTP.self]
        return URLSession(configuration: configuration)
    }
}

/// Lock-protected box for handler-side state (request counts, captured headers).
final class TestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&stored)
    }
}

extension URLRequest {
    /// URLProtocol surfaces POST bodies as a stream; drain it.
    var bodyBytes: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

    /// Decode the JSON-RPC id/method out of a request body.
    var rpcCall: (id: Int?, method: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: bodyBytes) as? [String: Any] else {
            return (nil, nil)
        }
        return (json["id"] as? Int, json["method"] as? String)
    }

    /// Decode form-urlencoded body fields.
    var formFields: [String: String] {
        guard let body = String(data: bodyBytes, encoding: .utf8) else { return [:] }
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        return fields
    }
}

// MARK: - Fakes

final class MemoryOAuthStore: MCPOAuthStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [URL: MCPOAuthState] = [:]

    init(preloaded: [URL: MCPOAuthState] = [:]) {
        states = preloaded
    }

    func load(server: URL) async throws -> MCPOAuthState? {
        get(server)
    }

    func save(_ state: MCPOAuthState, server: URL) async throws {
        set(state, server)
    }

    private func get(_ server: URL) -> MCPOAuthState? {
        lock.lock()
        defer { lock.unlock() }
        return states[server]
    }

    private func set(_ state: MCPOAuthState, _ server: URL) {
        lock.lock()
        defer { lock.unlock() }
        states[server] = state
    }

    var all: [URL: MCPOAuthState] {
        lock.lock()
        defer { lock.unlock() }
        return states
    }
}

/// Presenter that behaves like a user clicking straight through Google SSO:
/// bounces back to the redirect URI with a fixed code and the echoed state.
/// Captures the authorization URL for assertions.
struct AutoApprovePresenter: MCPOAuthPresenter {
    let code: String
    let captured: TestBox<URL?>

    init(code: String = "test-code", captured: TestBox<URL?> = TestBox(nil)) {
        self.code = code
        self.captured = captured
    }

    func present(authorizationURL: URL, redirectURI: URL) async throws -> URL {
        captured.value = authorizationURL
        let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = items.first { $0.name == "state" }?.value ?? ""
        var redirect = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)!
        redirect.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "state", value: state),
        ]
        return redirect.url!
    }
}

// MARK: - Response builders

enum HubFixture {
    static func jsonHeaders(session: String? = nil) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if let session { headers["Mcp-Session-Id"] = session }
        return headers
    }

    static func initializeResult(id: Int, session: String? = nil) -> (Int, [String: String], Data) {
        let body = """
        {"jsonrpc":"2.0","id":\(id),"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"hub","version":"1"}}}
        """
        return (200, jsonHeaders(session: session), Data(body.utf8))
    }

    static func toolsResult(id: Int) -> (Int, [String: String], Data) {
        let body = """
        {"jsonrpc":"2.0","id":\(id),"result":{"tools":[{"name":"hub_search_tools","description":"Search the catalog","inputSchema":{"type":"object","properties":{"query":{"type":"string"}}}}]}}
        """
        return (200, jsonHeaders(), Data(body.utf8))
    }

    static func callResultSSE(id: Int, text: String) -> (Int, [String: String], Data) {
        let body = """
        event: message\r
        data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}\r
        \r
        event: message\r
        data: {"jsonrpc":"2.0","id":\(id),"result":{"content":[{"type":"text","text":"\(text)"}],"isError":false}}\r
        \r

        """
        return (200, ["Content-Type": "text/event-stream"], Data(body.utf8))
    }

    static func protectedResourceMetadata(host: String) -> Data {
        Data("""
        {"resource":"https://\(host)/mcp","authorization_servers":["https://\(host)"]}
        """.utf8)
    }

    static func authorizationServerMetadata(host: String) -> Data {
        Data("""
        {"issuer":"https://\(host)","authorization_endpoint":"https://\(host)/auth/oauth/authorize","token_endpoint":"https://\(host)/auth/oauth/token","registration_endpoint":"https://\(host)/auth/oauth/register","scopes_supported":["tools:execute","resources:read","prompts:read"]}
        """.utf8)
    }
}
