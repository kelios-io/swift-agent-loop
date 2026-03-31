import Foundation

/// Tool that spawns a child AgentLoop to perform a task autonomously.
///
/// When Claude calls this tool, it creates a subagent with a specialized configuration
/// (tools, model, system prompt) based on the requested type. The subagent runs to
/// completion and returns its aggregated text output.
///
/// Depth enforcement: subagent tool lists never include SubagentTool,
/// so children cannot spawn grandchildren (flat teams, max depth 2).
public final class SubagentTool: AgentTool, @unchecked Sendable {
    public let name = "Agent"
    public let description = """
        Launch a subagent to handle a task autonomously. The subagent runs independently \
        with its own tools and returns the result. Use 'explore' for code research, \
        'plan' for designing implementation approaches, or 'general' for full tool access.
        """
    public let isReadOnly = false
    public let isConcurrencySafe = true
    public var timeout: TimeInterval { 600 }

    public var inputSchema: InputSchema {
        InputSchema([
            "type": "object",
            "required": ["prompt"],
            "properties": [
                "prompt": [
                    "type": "string",
                    "description": "The task for the subagent to perform",
                ],
                "subagent_type": [
                    "type": "string",
                    "description": "Type of subagent: 'general', 'explore', or 'plan'",
                    "enum": ["general", "explore", "plan"],
                ],
            ] as [String: Any],
        ])
    }

    private let client: any MessageStreaming
    private let parentModel: String

    public init(client: any MessageStreaming, parentModel: String) {
        self.client = client
        self.parentModel = parentModel
    }

    // MARK: - Validation

    public func validate(input: [String: Any], context: ToolContext) throws {
        guard let prompt = input["prompt"] as? String, !prompt.isEmpty else {
            throw ToolError.missingParameter("prompt")
        }
        if let type = input["subagent_type"] as? String {
            guard ["general", "explore", "plan"].contains(type) else {
                throw ToolError.invalidParameter(
                    name: "subagent_type",
                    message: "Must be one of: general, explore, plan"
                )
            }
        }
    }

    // MARK: - Execution

    public func execute(input: [String: Any], context: ToolContext) async throws -> ToolResult {
        guard let prompt = input["prompt"] as? String, !prompt.isEmpty else {
            return .error("prompt is required and must be a non-empty string")
        }

        let typeName = input["subagent_type"] as? String ?? "general"
        let definition = makeDefinition(type: typeName)

        let configuration = AgentConfiguration(
            model: definition.model ?? parentModel,
            maxTokens: definition.maxTokens,
            maxTurns: definition.maxTurns,
            systemPrompt: definition.systemPrompt,
            tools: definition.makeTools(),
            permissionCallback: nil,
            workingDirectory: context.workingDirectory,
            thinkingEnabled: definition.thinkingEnabled,
            thinkingBudgetTokens: definition.thinkingBudgetTokens
        )

        let loop = AgentLoop(client: client, configuration: configuration)
        let stream = await loop.run(prompt: prompt)

        var output = ""
        var lastError: String?

        for await event in stream {
            switch event {
            case .textDelta(let text):
                output += text
            case .error(let error):
                lastError = "\(error)"
            case .done:
                break
            default:
                break
            }
        }

        if output.isEmpty, let error = lastError {
            return .error("Subagent failed: \(error)")
        }

        return .success(output.isEmpty ? "(subagent produced no output)" : output)
    }

    // MARK: - Private

    private func makeDefinition(type: String) -> SubagentDefinition {
        switch type {
        case "explore":
            return .explore()
        case "plan":
            return .plan(parentModel: parentModel)
        default:
            return .general(parentModel: parentModel)
        }
    }
}
