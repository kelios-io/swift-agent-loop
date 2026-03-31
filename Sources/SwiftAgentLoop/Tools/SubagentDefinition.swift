import Foundation

/// Defines a subagent archetype — tools, model, system prompt, and execution limits.
public struct SubagentDefinition: Sendable {
    public let name: String
    public let systemPrompt: String
    public let model: String?
    public let maxTurns: Int
    public let maxTokens: Int
    public let thinkingEnabled: Bool
    public let thinkingBudgetTokens: Int?
    /// Factory that creates the tool set for this subagent type.
    /// Called at execution time so tools get the correct working directory.
    let makeTools: @Sendable () -> [any AgentTool]

    public init(
        name: String,
        systemPrompt: String,
        model: String? = nil,
        maxTurns: Int = 50,
        maxTokens: Int = 16384,
        thinkingEnabled: Bool = false,
        thinkingBudgetTokens: Int? = nil,
        makeTools: @escaping @Sendable () -> [any AgentTool]
    ) {
        self.name = name
        self.systemPrompt = systemPrompt
        self.model = model
        self.maxTurns = maxTurns
        self.maxTokens = maxTokens
        self.thinkingEnabled = thinkingEnabled
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.makeTools = makeTools
    }
}

// MARK: - Built-in Archetypes

extension SubagentDefinition {

    /// General-purpose subagent with all tools. Inherits parent model.
    public static func general(parentModel: String) -> SubagentDefinition {
        SubagentDefinition(
            name: "general",
            systemPrompt: """
                You are an autonomous agent. Complete the task described in the prompt. \
                Work independently — do not ask for clarification. Use the available tools \
                to read, write, and modify files as needed. Be thorough but concise in your response.
                """,
            model: parentModel,
            maxTurns: 50,
            makeTools: { Self.allFileTools() }
        )
    }

    /// Exploration subagent — read-only tools, fast model, for understanding code.
    public static func explore() -> SubagentDefinition {
        SubagentDefinition(
            name: "explore",
            systemPrompt: """
                You are a code exploration agent. Your goal is to find and understand code \
                in the codebase. Use Read, Glob, and Grep to search for files, patterns, and \
                content. Report your findings clearly and concisely. Do not modify any files.
                """,
            model: "claude-haiku-4-5-20251001",
            maxTurns: 20,
            makeTools: { Self.readOnlyTools() }
        )
    }

    /// Planning subagent — read-only tools, for designing implementation approaches.
    public static func plan(parentModel: String) -> SubagentDefinition {
        SubagentDefinition(
            name: "plan",
            systemPrompt: """
                You are a software architect agent. Your goal is to design an implementation \
                plan for the task described. Explore the codebase with Read, Glob, and Grep \
                to understand existing patterns, then produce a concrete step-by-step plan \
                with file paths and key decisions. Do not modify any files.
                """,
            model: parentModel,
            maxTurns: 20,
            makeTools: { Self.readOnlyTools() }
        )
    }

    // MARK: - Tool Factories

    private static func allFileTools() -> [any AgentTool] {
        [ReadTool(), WriteTool(), EditTool(), BashTool(), GlobTool(), GrepTool()]
    }

    private static func readOnlyTools() -> [any AgentTool] {
        [ReadTool(), GlobTool(), GrepTool()]
    }
}
