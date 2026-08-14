import Foundation

/// Bridges one MCP server tool into the agent loop's `AgentTool` protocol.
/// Validation is left to the server (it owns the schema); errors come back
/// as `ToolResult(isError: true)` so the model can adapt.
public struct MCPTool: AgentTool {
    public let name: String
    public let description: String
    public let inputSchema: InputSchema
    public let isReadOnly: Bool
    public let timeout: TimeInterval

    private let client: any MCPConnection

    public init(info: MCPToolInfo, client: any MCPConnection, isReadOnly: Bool = false, timeout: TimeInterval = 60) {
        self.name = info.name
        self.description = info.description
        self.inputSchema = InputSchema((info.inputSchema.anyValue as? [String: Any]) ?? ["type": "object"])
        self.client = client
        self.isReadOnly = isReadOnly
        self.timeout = timeout
    }

    public func validate(input: [String: Any], context: ToolContext) throws {
        // Server-side validation; nothing to check locally.
    }

    public func execute(input: [String: Any], context: ToolContext) async throws -> ToolResult {
        do {
            // Bridge before the actor hop so only Sendable values cross.
            let arguments = JSONValue(bridging: input)
            let result = try await client.callTool(name, arguments: arguments)
            return ToolResult(content: result.text, isError: result.isError)
        } catch {
            return .error("MCP call failed: \(error)")
        }
    }
}
