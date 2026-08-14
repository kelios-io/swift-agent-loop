import Foundation
import Testing
@testable import SwiftAgentLoop

@Suite("MCPHTTPClient")
struct MCPHTTPClientTests {
    @Test("Handshake captures the session id and sends protocol headers afterwards")
    func handshakeAndHeaders() async throws {
        let host = "http-handshake.test"
        let listHeaders = TestBox<[String: String]>([:])
        let sawInitializedNotification = TestBox(false)

        MockHTTP.register(host: host) { request in
            let call = request.rpcCall
            guard let id = call.id else {
                sawInitializedNotification.value = call.method == "notifications/initialized"
                return (202, [:], Data())
            }
            switch call.method {
            case "initialize":
                return HubFixture.initializeResult(id: id, session: "sess-1")
            case "tools/list":
                listHeaders.value = request.allHTTPHeaderFields ?? [:]
                return HubFixture.toolsResult(id: id)
            default:
                return (404, [:], Data())
            }
        }

        let client = MCPHTTPClient(endpoint: URL(string: "https://\(host)/mcp")!, session: MockHTTP.makeSession())
        try await client.start(clientName: "laplace", clientVersion: "0.1.0")
        #expect(sawInitializedNotification.value)

        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(tools.first?.name == "hub_search_tools")
        #expect(listHeaders.value["Mcp-Session-Id"] == "sess-1")
        #expect(listHeaders.value["MCP-Protocol-Version"] == "2025-06-18")
        #expect(listHeaders.value["Accept"] == "application/json, text/event-stream")

        await client.shutdown()
    }

    @Test("tools/call result arrives on an SSE body, skipping interleaved notifications")
    func sseResponse() async throws {
        let host = "http-sse.test"
        MockHTTP.register(host: host) { request in
            let call = request.rpcCall
            guard let id = call.id else { return (202, [:], Data()) }
            switch call.method {
            case "initialize": return HubFixture.initializeResult(id: id)
            case "tools/call": return HubFixture.callResultSSE(id: id, text: "hub says hi")
            default: return (404, [:], Data())
            }
        }

        let client = MCPHTTPClient(endpoint: URL(string: "https://\(host)/mcp")!, session: MockHTTP.makeSession())
        try await client.start()
        let result = try await client.callTool("hub_search_tools", arguments: .object(["query": .string("linear")]))
        #expect(result.text == "hub says hi")
        #expect(result.isError == false)
    }

    @Test("JSON-RPC errors and HTTP errors map to typed MCPErrors")
    func errorMapping() async throws {
        let host = "http-errors.test"
        let mode = TestBox("rpc-error")
        MockHTTP.register(host: host) { request in
            let call = request.rpcCall
            guard call.id != nil else { return (202, [:], Data()) }
            switch call.method {
            case "initialize": return HubFixture.initializeResult(id: call.id ?? 0)
            default:
                if mode.value == "rpc-error" {
                    return (200, HubFixture.jsonHeaders(), Data(
                        #"{"jsonrpc":"2.0","id":\#(call.id ?? 0),"error":{"code":-32000,"message":"boom"}}"#.utf8
                    ))
                }
                return (503, [:], Data("upstream gateway unavailable".utf8))
            }
        }

        let client = MCPHTTPClient(endpoint: URL(string: "https://\(host)/mcp")!, session: MockHTTP.makeSession())
        try await client.start()

        do {
            _ = try await client.callTool("x", arguments: .object([:]))
            Issue.record("expected serverError")
        } catch MCPError.serverError(let code, let message) {
            #expect(code == -32000)
            #expect(message == "boom")
        }

        mode.value = "http-error"
        do {
            _ = try await client.callTool("x", arguments: .object([:]))
            Issue.record("expected httpError")
        } catch MCPError.httpError(let status, let body) {
            #expect(status == 503)
            #expect(body.contains("gateway"))
        }
    }

    @Test("401 triggers the OAuth flow, then the request is replayed with the token")
    func unauthorizedRunsOAuthAndRetries() async throws {
        let host = "http-401.test"
        let endpoint = URL(string: "https://\(host)/mcp")!
        let authorizedCalls = TestBox(0)

        MockHTTP.register(host: host) { request in
            let path = request.url!.path
            switch path {
            case "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource":
                return (200, HubFixture.jsonHeaders(), HubFixture.protectedResourceMetadata(host: host))
            case "/.well-known/oauth-authorization-server":
                return (200, HubFixture.jsonHeaders(), HubFixture.authorizationServerMetadata(host: host))
            case "/auth/oauth/register":
                return (201, HubFixture.jsonHeaders(), Data(#"{"client_id":"c-hub"}"#.utf8))
            case "/auth/oauth/token":
                return (200, HubFixture.jsonHeaders(), Data(
                    #"{"access_token":"at-hub","token_type":"Bearer","expires_in":3600,"refresh_token":"rt-hub"}"#.utf8
                ))
            case "/mcp":
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer at-hub" else {
                    return (401, ["WWW-Authenticate": #"Bearer resource_metadata="https://\#(host)/.well-known/oauth-protected-resource""#], Data())
                }
                authorizedCalls.withLock { $0 += 1 }
                let call = request.rpcCall
                guard let id = call.id else { return (202, [:], Data()) }
                switch call.method {
                case "initialize": return HubFixture.initializeResult(id: id, session: "sess-auth")
                case "tools/list": return HubFixture.toolsResult(id: id)
                default: return (404, [:], Data())
                }
            default:
                return (404, [:], Data())
            }
        }

        let oauth = MCPOAuthClient(
            configuration: MCPOAuthConfiguration(clientName: "laplace", redirectURI: URL(string: "laplace://oauth-callback")!),
            store: MemoryOAuthStore(),
            presenter: AutoApprovePresenter(),
            session: MockHTTP.makeSession()
        )
        let client = MCPHTTPClient(endpoint: endpoint, authorization: .oauth(oauth), session: MockHTTP.makeSession())

        // First-ever start: 401 → discovery/registration/PKCE/token → replay.
        try await client.start()
        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(authorizedCalls.value >= 3) // initialize + initialized + tools/list, all authenticated
    }

    @Test("Static bearer tokens ride every request")
    func staticBearer() async throws {
        let host = "http-bearer.test"
        let seenAuth = TestBox<String?>(nil)
        MockHTTP.register(host: host) { request in
            seenAuth.value = request.value(forHTTPHeaderField: "Authorization")
            let call = request.rpcCall
            guard let id = call.id else { return (202, [:], Data()) }
            switch call.method {
            case "initialize": return HubFixture.initializeResult(id: id)
            default: return HubFixture.toolsResult(id: id)
            }
        }

        let client = MCPHTTPClient(
            endpoint: URL(string: "https://\(host)/mcp")!,
            authorization: .bearer("lin_api_123"),
            session: MockHTTP.makeSession()
        )
        try await client.start()
        _ = try await client.listTools()
        #expect(seenAuth.value == "Bearer lin_api_123")
    }

    @Test("Authorization survives a same-origin slash redirect")
    func redirectKeepsAuthorization() async throws {
        let host = "http-redirect.test"
        let authAtTarget = TestBox<String?>(nil)
        MockHTTP.register(host: host) { request in
            // FastAPI-style: the canonical endpoint 307s to the slash variant.
            // (URL.path strips the trailing slash, so match the absolute string.)
            if !request.url!.absoluteString.hasSuffix("/mcp/") {
                return (307, ["Location": "https://\(host)/mcp/"], Data())
            }
            authAtTarget.value = request.value(forHTTPHeaderField: "Authorization")
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1" else {
                return (401, ["WWW-Authenticate": "Bearer"], Data())
            }
            let call = request.rpcCall
            guard let id = call.id else { return (202, [:], Data()) }
            switch call.method {
            case "initialize": return HubFixture.initializeResult(id: id)
            default: return HubFixture.toolsResult(id: id)
            }
        }

        let client = MCPHTTPClient(
            endpoint: URL(string: "https://\(host)/mcp")!,
            authorization: .bearer("tok-1"),
            session: MockHTTP.makeSession()
        )
        try await client.start()
        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(authAtTarget.value == "Bearer tok-1")
    }

    @Test("An expired session (404) re-initializes and replays the request")
    func sessionExpiryReinitializes() async throws {
        let host = "http-expiry.test"
        let sessionCounter = TestBox(0)
        let lastSeenSession = TestBox<String?>(nil)

        MockHTTP.register(host: host) { request in
            let call = request.rpcCall
            guard let id = call.id else { return (202, [:], Data()) }
            switch call.method {
            case "initialize":
                let next = sessionCounter.withLock { counter -> Int in
                    counter += 1
                    return counter
                }
                return HubFixture.initializeResult(id: id, session: "sess-\(next)")
            case "tools/list":
                let session = request.value(forHTTPHeaderField: "Mcp-Session-Id")
                lastSeenSession.value = session
                guard session == "sess-2" else { return (404, [:], Data()) }
                return HubFixture.toolsResult(id: id)
            default:
                return (404, [:], Data())
            }
        }

        let client = MCPHTTPClient(endpoint: URL(string: "https://\(host)/mcp")!, session: MockHTTP.makeSession())
        try await client.start()

        // sess-1 is rejected → client re-initializes (gets sess-2) → replay succeeds.
        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(lastSeenSession.value == "sess-2")
    }

    @Test("agentTools bridges hub tools over HTTP like any MCP server")
    func agentToolsBridge() async throws {
        let host = "http-bridge.test"
        MockHTTP.register(host: host) { request in
            let call = request.rpcCall
            guard let id = call.id else { return (202, [:], Data()) }
            switch call.method {
            case "initialize": return HubFixture.initializeResult(id: id)
            case "tools/list": return HubFixture.toolsResult(id: id)
            case "tools/call": return HubFixture.callResultSSE(id: id, text: "bridged")
            default: return (404, [:], Data())
            }
        }

        let client = MCPHTTPClient(endpoint: URL(string: "https://\(host)/mcp")!, session: MockHTTP.makeSession())
        try await client.start()
        let tools = try await client.agentTools(readOnly: true)
        let tool = try #require(tools.first)
        #expect(tool.name == "hub_search_tools")

        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        let result = try await tool.execute(input: ["query": "linear"], context: context)
        #expect(result.content == "bridged")
    }
}
