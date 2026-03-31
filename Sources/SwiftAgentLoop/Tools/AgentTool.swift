import Foundation

// MARK: - ToolResult

/// Result returned by a tool execution.
public struct ToolResult: Sendable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func success(_ content: String) -> ToolResult {
        ToolResult(content: content)
    }

    public static func error(_ message: String) -> ToolResult {
        ToolResult(content: message, isError: true)
    }
}

// MARK: - ToolContext

/// Context passed to tools during execution.
public struct ToolContext: Sendable {
    /// The working directory for file operations
    public let workingDirectory: URL

    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }
}

// MARK: - InputSchema

/// A Sendable wrapper around a JSON Schema dictionary for tool input parameters.
///
/// The underlying dictionary is set at init time and never mutated,
/// making `@unchecked Sendable` safe here.
public struct InputSchema: @unchecked Sendable {
    public let value: [String: Any]

    public init(_ value: [String: Any]) {
        self.value = value
    }
}

// MARK: - AgentTool

/// Protocol that all agent tools must conform to.
public protocol AgentTool: Sendable {
    /// Tool name as registered with the API (e.g. "Read", "Edit", "Bash")
    var name: String { get }

    /// Human-readable description of what the tool does
    var description: String { get }

    /// JSON Schema for the tool's input parameters (matches Claude API tool schemas)
    var inputSchema: InputSchema { get }

    /// Validate input before execution. Throws if invalid.
    func validate(input: [String: Any], context: ToolContext) throws

    /// Execute the tool with the given input.
    func execute(input: [String: Any], context: ToolContext) async throws -> ToolResult

    /// Whether this tool only reads state (safe for parallel execution)
    var isReadOnly: Bool { get }

    /// Whether this tool is safe to run concurrently with other tools
    var isConcurrencySafe: Bool { get }

    /// Maximum execution time in seconds before the tool is forcibly timed out.
    var timeout: TimeInterval { get }
}

// MARK: - AgentTool Defaults

extension AgentTool {
    public var isReadOnly: Bool { false }
    public var isConcurrencySafe: Bool { isReadOnly }
    public var timeout: TimeInterval { 120 }
}

// MARK: - ToolError

/// Errors thrown during tool validation or execution.
public enum ToolError: Error, Sendable {
    case missingParameter(String)
    case invalidParameter(name: String, message: String)
    case fileNotFound(String)
    case permissionDenied(String)
    case timeout
    case executionFailed(String)
}