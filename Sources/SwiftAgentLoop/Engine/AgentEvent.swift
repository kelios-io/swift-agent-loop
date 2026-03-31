/// Events emitted by the agentic loop, consumed by the UI layer.
public enum AgentEvent: Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case toolUseStart(id: String, name: String)
    case toolUseInput(id: String, partialJSON: String)
    case toolResult(id: String, output: String, isError: Bool)
    case usage(inputTokens: Int, outputTokens: Int, cacheRead: Int?, cacheCreation: Int?)
    case turnComplete(turnNumber: Int)
    case done(stopReason: StopReason)
    case error(AgentError)
}

public enum StopReason: Sendable {
    case completed
    case maxTurns
    case aborted
    case promptTooLong
}

public enum AgentError: Error, Sendable {
    case apiError(statusCode: Int, message: String)
    case networkError(String)
    case toolExecutionFailed(toolName: String, message: String)
    case maxTokensExhausted
    case invalidResponse(String)
    case cancelled
}