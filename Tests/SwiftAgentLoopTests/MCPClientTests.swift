import Foundation
import Testing
@testable import SwiftAgentLoop

@Suite("MCPClient")
struct MCPClientTests {
    // MARK: Envelope framing

    @Test("Decodes a result envelope")
    func decodesResult() throws {
        let json = #"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#
        let envelope = try JSONDecoder().decode(JSONRPCEnvelope.self, from: Data(json.utf8))
        #expect(envelope.id == 7)
        #expect(envelope.error == nil)
        if case .object(let object)? = envelope.result, case .bool(true)? = object["ok"] {
        } else {
            Issue.record("expected result object")
        }
    }

    @Test("Decodes an error envelope")
    func decodesError() throws {
        let json = #"{"jsonrpc":"2.0","id":7,"error":{"code":-32601,"message":"nope"}}"#
        let envelope = try JSONDecoder().decode(JSONRPCEnvelope.self, from: Data(json.utf8))
        #expect(envelope.error?.code == -32601)
        #expect(envelope.error?.message == "nope")
    }

    @Test("JSONValue bridging round-trips loose dictionaries")
    func bridging() {
        let input: [String: Any] = ["ref": "MAPS-1234", "count": 3, "flag": true, "nested": ["a": [1, 2]]]
        let bridged = JSONValue(bridging: input)
        let back = bridged.anyValue as? [String: Any]
        #expect(back?["ref"] as? String == "MAPS-1234")
        #expect(back?["count"] as? Int == 3)
        #expect(back?["flag"] as? Bool == true)
        #expect(((back?["nested"] as? [String: Any])?["a"] as? [Any])?.count == 2)
    }

    // MARK: Integration against a scripted stdio server

    /// Writes a bash script that plays a fixed MCP session: initialize →
    /// (initialized) → tools/list → tools/call. Ids match the client's
    /// incrementing counter (1, 2, 3).
    private func makeFakeServer(toolCallResponse: String) throws -> URL {
        let script = """
        #!/bin/bash
        read -r _line
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fake","version":"0"}}}'
        read -r _line
        read -r _line
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"get_item","description":"Get one work item","inputSchema":{"type":"object","properties":{"ref":{"type":"string"}},"required":["ref"]}}]}}'
        read -r _line
        printf '%s\\n' '\(toolCallResponse)'
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-mcp-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("Handshake, tools/list, tools/call against a scripted server")
    func endToEnd() async throws {
        let server = try makeFakeServer(
            toolCallResponse: #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"MAPS-1234: ok"}],"isError":false}}"#
        )
        defer { try? FileManager.default.removeItem(at: server) }

        let client = MCPClient(executable: "/bin/bash", arguments: [server.path])
        try await client.start()

        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(tools.first?.name == "get_item")
        #expect(tools.first?.description == "Get one work item")

        let result = try await client.callTool("get_item", arguments: .object(["ref": .string("MAPS-1234")]))
        #expect(result.text == "MAPS-1234: ok")
        #expect(result.isError == false)

        await client.shutdown()
    }

    @Test("Server JSON-RPC error surfaces as MCPError.serverError")
    func serverError() async throws {
        let server = try makeFakeServer(
            toolCallResponse: #"{"jsonrpc":"2.0","id":3,"error":{"code":-32000,"message":"boom"}}"#
        )
        defer { try? FileManager.default.removeItem(at: server) }

        let client = MCPClient(executable: "/bin/bash", arguments: [server.path])
        try await client.start()
        _ = try await client.listTools()

        await #expect(throws: MCPError.self) {
            _ = try await client.callTool("get_item", arguments: .object([:]))
        }
        await client.shutdown()
    }

    @Test("MCPTool adapter exposes server schema and executes calls")
    func adapter() async throws {
        let server = try makeFakeServer(
            toolCallResponse: #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"one blocked item"}]}}"#
        )
        defer { try? FileManager.default.removeItem(at: server) }

        let client = MCPClient(executable: "/bin/bash", arguments: [server.path])
        try await client.start()
        let tools = try await client.agentTools(readOnly: true)
        #expect(tools.count == 1)
        let tool = try #require(tools.first)
        #expect(tool.name == "get_item")
        #expect(tool.isReadOnly)
        #expect((tool.inputSchema.value["type"] as? String) == "object")

        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        let result = try await tool.execute(input: ["ref": "MAPS-1275"], context: context)
        #expect(result.content == "one blocked item")
        #expect(result.isError == false)

        await client.shutdown()
    }
}
