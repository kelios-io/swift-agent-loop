import Foundation

/// Protocol for agent transport implementations.
/// Abstracts over different backends (CLI process vs native API client).
public protocol AgentTransport: Sendable {
    /// Start a new agent run with the given prompt.
    func start(prompt: String, systemPrompt: String?, workingDirectory: URL) async -> AsyncStream<AgentEvent>

    /// Respond to a permission request for a specific tool use.
    func respond(to toolUseId: String, decision: ToolDecision) async throws

    /// Cancel the current run.
    func cancel() async
}

/// Native transport using the Anthropic Messages API directly.
public actor NativeTransport: AgentTransport {
    private let client: AnthropicClient
    private let promptBuilder: SystemPromptBuilder
    private let tools: [any AgentTool]
    private let permissionCallback: PermissionCallback?
    private let model: String
    private let maxTokens: Int
    private let maxTurns: Int

    private var currentLoop: AgentLoop?

    public init(
        apiKey: String,
        model: String = "claude-sonnet-4-6",
        maxTokens: Int = 4096,
        maxTurns: Int = 50,
        tools: [any AgentTool] = [],
        permissionCallback: PermissionCallback? = nil
    ) {
        self.client = AnthropicClient(apiKey: apiKey)
        self.promptBuilder = SystemPromptBuilder()
        self.tools = tools
        self.permissionCallback = permissionCallback
        self.model = model
        self.maxTokens = maxTokens
        self.maxTurns = maxTurns
    }

    public func start(prompt: String, systemPrompt: String?, workingDirectory: URL) async -> AsyncStream<AgentEvent> {
        // Build system prompt
        let config = SystemPromptBuilder.Configuration(
            workingDirectory: workingDirectory,
            model: model,
            claudeMDContents: nil
        )
        let fullSystemPrompt = systemPrompt ?? promptBuilder.build(configuration: config)

        // Create agent loop
        let configuration = AgentConfiguration(
            model: model,
            maxTokens: maxTokens,
            maxTurns: maxTurns,
            systemPrompt: fullSystemPrompt,
            tools: tools,
            permissionCallback: permissionCallback,
            workingDirectory: workingDirectory
        )

        let loop = AgentLoop(client: client, configuration: configuration)
        self.currentLoop = loop

        return await loop.run(prompt: prompt)
    }

    public func respond(to toolUseId: String, decision: ToolDecision) async throws {
        // For native transport, permissions are handled inline via the callback.
        // This method would be used for deferred permissions in a future version.
    }

    public func cancel() async {
        await currentLoop?.cancel()
    }
}

// MARK: - Default Tools Factory

extension NativeTransport {
    /// Create a transport with all built-in tools registered.
    public static func withDefaultTools(
        apiKey: String,
        model: String = "claude-sonnet-4-6",
        permissionCallback: PermissionCallback? = nil
    ) -> NativeTransport {
        NativeTransport(
            apiKey: apiKey,
            model: model,
            tools: [
                ReadTool(),
                WriteTool(),
                EditTool(),
                BashTool(),
                GlobTool(),
                GrepTool()
            ],
            permissionCallback: permissionCallback
        )
    }
}