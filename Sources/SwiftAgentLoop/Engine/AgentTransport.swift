import Foundation

/// Protocol for agent transport implementations.
/// Abstracts over different backends (CLI process vs native API client).
public protocol AgentTransport: Sendable {
    /// Start a new agent run with the given prompt.
    func start(prompt: String, systemPrompt: String?, workingDirectory: URL) async -> AsyncStream<AgentEvent>

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
    private let temperature: Double?
    private let topP: Double?
    private let thinkingEnabled: Bool
    private let thinkingBudgetTokens: Int?
    private let contextCompressionEnabled: Bool

    private var currentLoop: AgentLoop?

    public init(
        apiKey: String,
        model: String = "claude-sonnet-4-6",
        maxTokens: Int = 4096,
        maxTurns: Int = 50,
        tools: [any AgentTool] = [],
        permissionCallback: PermissionCallback? = nil,
        requestTimeout: TimeInterval = 300,
        temperature: Double? = nil,
        topP: Double? = nil,
        thinkingEnabled: Bool = false,
        thinkingBudgetTokens: Int? = nil,
        contextCompressionEnabled: Bool = false
    ) {
        self.client = AnthropicClient(apiKey: apiKey, requestTimeout: requestTimeout)
        self.promptBuilder = SystemPromptBuilder()
        self.tools = tools
        self.permissionCallback = permissionCallback
        self.model = model
        self.maxTokens = maxTokens
        self.maxTurns = maxTurns
        self.temperature = temperature
        self.topP = topP
        self.thinkingEnabled = thinkingEnabled
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.contextCompressionEnabled = contextCompressionEnabled
    }

    public func start(prompt: String, systemPrompt: String?, workingDirectory: URL) async -> AsyncStream<AgentEvent> {
        // Load CLAUDE.md from project directory tree
        let claudeMDContents = Self.loadClaudeMD(from: workingDirectory)

        // Build system prompt
        let config = SystemPromptBuilder.Configuration(
            workingDirectory: workingDirectory,
            model: model,
            claudeMDContents: claudeMDContents
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
            workingDirectory: workingDirectory,
            temperature: temperature,
            topP: topP,
            thinkingEnabled: thinkingEnabled,
            thinkingBudgetTokens: thinkingBudgetTokens,
            contextCompressionEnabled: contextCompressionEnabled
        )

        let loop = AgentLoop(client: client, configuration: configuration)
        self.currentLoop = loop

        return await loop.run(prompt: prompt)
    }

    public func cancel() async {
        await currentLoop?.cancel()
    }

    // MARK: - CLAUDE.md Loading

    /// Walk from workingDirectory up to filesystem root looking for CLAUDE.md.
    private static func loadClaudeMD(from workingDirectory: URL) -> String? {
        let fileManager = FileManager.default
        var directory = workingDirectory

        while true {
            let claudeMDPath = directory.appendingPathComponent("CLAUDE.md").path
            if fileManager.fileExists(atPath: claudeMDPath),
               let data = fileManager.contents(atPath: claudeMDPath),
               let text = String(data: data, encoding: .utf8),
               !text.isEmpty {
                return text
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                break // reached filesystem root
            }
            directory = parent
        }
        return nil
    }
}

// MARK: - Default Tools Factory

extension NativeTransport {
    /// Create a transport with all built-in tools registered.
    public static func withDefaultTools(
        apiKey: String,
        model: String = "claude-sonnet-4-6",
        permissionCallback: PermissionCallback? = nil,
        requestTimeout: TimeInterval = 300,
        temperature: Double? = nil,
        topP: Double? = nil,
        thinkingEnabled: Bool = false,
        thinkingBudgetTokens: Int? = nil,
        contextCompressionEnabled: Bool = false
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
            permissionCallback: permissionCallback,
            requestTimeout: requestTimeout,
            temperature: temperature,
            topP: topP,
            thinkingEnabled: thinkingEnabled,
            thinkingBudgetTokens: thinkingBudgetTokens,
            contextCompressionEnabled: contextCompressionEnabled
        )
    }
}
