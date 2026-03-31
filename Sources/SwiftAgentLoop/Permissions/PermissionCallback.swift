import Foundation

/// Decision returned by the permission callback for a tool execution request.
public enum ToolDecision: Sendable {
    /// Allow this single execution
    case approve
    /// Allow this tool for the remainder of the session
    case approveForSession
    /// Block execution with a reason shown to the model
    case block(reason: String)
}

/// Callback invoked before each tool execution.
/// Parameters: tool name, tool input dictionary
/// Returns: the permission decision
public typealias PermissionCallback = @Sendable (String, [String: Any]) async -> ToolDecision