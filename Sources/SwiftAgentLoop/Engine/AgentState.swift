/// Tracks the state of an agentic loop execution.
/// Owned by AgentLoop actor — not shared across isolation boundaries.
struct AgentState: Sendable {
    /// Full conversation history sent to the API.
    var messages: [Message] = []

    /// Current turn number (increments each tool-use cycle).
    var turnCount: Int = 0

    /// Number of times we've retried with higher max_tokens.
    var maxOutputTokensRecoveryCount: Int = 0

    /// Whether we've attempted reactive compaction (E3 — unused in E1).
    var hasAttemptedReactiveCompact: Bool = false

    /// Maximum turns before stopping (default 50).
    var maxTurns: Int = 50

    /// Whether the loop has been cancelled.
    var isCancelled: Bool = false

    /// Last reported input token count from API usage events.
    /// Used for context window monitoring and autocompact threshold (E3).
    var lastInputTokenCount: Int = 0
}