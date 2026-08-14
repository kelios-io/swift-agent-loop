import Foundation

// MARK: - MCPConnection

/// A connection to one MCP server, independent of transport. `MCPClient`
/// (stdio) and `MCPHTTPClient` (Streamable HTTP) both conform; `MCPTool`
/// and the agent loop only ever see this surface.
public protocol MCPConnection: Actor {
    /// Fetch the server's tool catalog (follows `nextCursor` pagination).
    func listTools() async throws -> [MCPToolInfo]
    /// Invoke a tool. Text content parts are concatenated with newlines.
    func callTool(_ name: String, arguments: JSONValue) async throws -> MCPCallResult
    /// Tear down the connection. Pending requests fail with `.connectionClosed`.
    func shutdown() async
}

extension MCPConnection {
    /// Convenience: fetch the server's catalog as ready-to-register agent tools.
    /// `readOnly` marks every tool as safe for parallel execution — set it only
    /// for servers you know are read-only (permission callbacks still apply).
    public func agentTools(readOnly: Bool = false) async throws -> [any AgentTool] {
        try await listTools().map { MCPTool(info: $0, client: self, isReadOnly: readOnly) }
    }
}

// MARK: - Wire parsing shared by both transports

enum MCPWire {
    static func initializeParams(clientName: String, clientVersion: String, protocolVersion: String) -> JSONValue {
        .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion),
            ]),
        ])
    }

    /// Decode one page of a `tools/list` result. Returns the cursor for the
    /// next page, or nil when this was the last one.
    static func decodeToolsPage(_ result: JSONValue) throws -> (tools: [MCPToolInfo], nextCursor: JSONValue?) {
        guard case .object(let object) = result,
              case .array(let entries)? = object["tools"] else {
            throw MCPError.protocolError("tools/list: missing tools array")
        }
        var tools: [MCPToolInfo] = []
        for entry in entries {
            guard case .object(let tool) = entry,
                  case .string(let name)? = tool["name"] else { continue }
            var description = ""
            if case .string(let text)? = tool["description"] { description = text }
            tools.append(MCPToolInfo(
                name: name,
                description: description,
                inputSchema: tool["inputSchema"] ?? .object(["type": .string("object")])
            ))
        }
        var cursor = object["nextCursor"]
        if case .null = cursor { cursor = nil }
        return (tools, cursor)
    }

    /// Decode a `tools/call` result into concatenated text parts.
    static func decodeCallResult(_ result: JSONValue) throws -> MCPCallResult {
        guard case .object(let object) = result else {
            throw MCPError.protocolError("tools/call: non-object result")
        }
        var isError = false
        if case .bool(let flag)? = object["isError"] { isError = flag }
        var parts: [String] = []
        if case .array(let content)? = object["content"] {
            for part in content {
                guard case .object(let block) = part else { continue }
                if case .string("text")? = block["type"], case .string(let text)? = block["text"] {
                    parts.append(text)
                } else if case .string(let kind)? = block["type"] {
                    parts.append("[unsupported content type: \(kind)]")
                }
            }
        }
        return MCPCallResult(text: parts.joined(separator: "\n"), isError: isError)
    }
}
