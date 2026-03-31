import Foundation

// MARK: - AgentConfiguration

/// Configuration for an agent loop execution.
public struct AgentConfiguration: Sendable {
    public let model: String
    public let maxTokens: Int
    public let maxTurns: Int
    public let systemPrompt: String?
    public let tools: [any AgentTool]
    public let permissionCallback: PermissionCallback?
    public let workingDirectory: URL
    public let temperature: Double?
    public let topP: Double?
    public let thinkingEnabled: Bool
    public let thinkingBudgetTokens: Int?
    public let contextCompressionEnabled: Bool

    public init(
        model: String = "claude-sonnet-4-20250514",
        maxTokens: Int = 16384,
        maxTurns: Int = 50,
        systemPrompt: String? = nil,
        tools: [any AgentTool] = [],
        permissionCallback: PermissionCallback? = nil,
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        temperature: Double? = nil,
        topP: Double? = nil,
        thinkingEnabled: Bool = false,
        thinkingBudgetTokens: Int? = nil,
        contextCompressionEnabled: Bool = false
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.maxTurns = maxTurns
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.permissionCallback = permissionCallback
        self.workingDirectory = workingDirectory
        self.temperature = temperature
        self.topP = topP
        self.thinkingEnabled = thinkingEnabled
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.contextCompressionEnabled = contextCompressionEnabled
    }
}

// MARK: - AgentLoop

/// Core agentic loop actor. Owns conversation state and drives the
/// prompt -> API -> tool-use -> tool-result cycle.
public actor AgentLoop {
    private let client: any MessageStreaming
    private let configuration: AgentConfiguration
    private var state: AgentState
    private let tools: [String: any AgentTool]
    /// Tools approved for the entire session (via `.approveForSession`).
    private var sessionApprovedTools: Set<String> = []

    public init(client: any MessageStreaming, configuration: AgentConfiguration) {
        self.client = client
        self.configuration = configuration
        self.state = AgentState(maxTurns: configuration.maxTurns)
        var toolMap: [String: any AgentTool] = [:]
        for tool in configuration.tools {
            toolMap[tool.name] = tool
        }
        self.tools = toolMap
    }

    // MARK: - Public API

    /// Run the agentic loop with a user prompt. Returns an async stream of events.
    public func run(prompt: String) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.executeLoop(prompt: prompt, continuation: continuation)
            }
        }
    }

    /// Cancel the current loop execution.
    public func cancel() {
        state.isCancelled = true
    }

    /// Reset state for a new conversation (keeps tools and config).
    public func reset() {
        state = AgentState(maxTurns: configuration.maxTurns)
        sessionApprovedTools = []
    }

    // MARK: - Main Loop

    private func executeLoop(
        prompt: String,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        // 1. Append user message to history
        state.messages.append(Message(role: .user, content: .text(prompt)))

        // 2. Main agentic loop
        while !state.isCancelled && state.turnCount < state.maxTurns {
            let request = buildRequest()

            // Stream the API response and collect content blocks
            let streamResult = await streamResponse(request: request, continuation: continuation)

            switch streamResult {
            case .failure(let error):
                continuation.yield(.error(error))
                continuation.finish()
                return

            case .success(let response):
                // Append the assistant message to history
                let assistantMessage = Message(
                    role: .assistant,
                    content: .blocks(response.contentBlocks)
                )
                state.messages.append(assistantMessage)

                // Route on stop reason
                switch response.stopReason {
                case "tool_use":
                    // Recovery succeeded — reset counter
                    state.maxOutputTokensRecoveryCount = 0

                    let toolUseBlocks = response.contentBlocks.compactMap { block -> ToolUseBlock? in
                        if case .toolUse(let toolUse) = block { return toolUse }
                        return nil
                    }

                    guard !toolUseBlocks.isEmpty else {
                        continuation.yield(.error(.invalidResponse("tool_use stop reason but no tool_use blocks")))
                        continuation.finish()
                        return
                    }

                    // Execute tools and collect results
                    let toolResults = await executeTools(
                        toolUseBlocks: toolUseBlocks,
                        continuation: continuation
                    )

                    // Check if cancelled during tool execution
                    if state.isCancelled {
                        continuation.yield(.done(stopReason: .aborted))
                        continuation.finish()
                        return
                    }

                    // Append tool results as a user message
                    let resultBlocks = toolResults.map { ContentBlock.toolResult($0) }
                    state.messages.append(Message(role: .user, content: .blocks(resultBlocks)))

                    state.turnCount += 1
                    continuation.yield(.turnComplete(turnNumber: state.turnCount))
                    // Continue loop — send results back to the model

                case "end_turn":
                    // Recovery succeeded — reset counter
                    state.maxOutputTokensRecoveryCount = 0
                    continuation.yield(.done(stopReason: .completed))
                    continuation.finish()
                    return

                case "max_tokens":
                    state.maxOutputTokensRecoveryCount += 1
                    if state.maxOutputTokensRecoveryCount > 3 {
                        continuation.yield(.error(.maxTokensExhausted))
                        continuation.finish()
                        return
                    }
                    // Continue loop — the buildRequest will use a higher token limit

                default:
                    // Unknown or nil stop reason — treat as completed
                    continuation.yield(.done(stopReason: .completed))
                    continuation.finish()
                    return
                }
            }
        }

        // Exited loop — either cancelled or hit max turns
        if state.isCancelled {
            continuation.yield(.done(stopReason: .aborted))
        } else {
            continuation.yield(.done(stopReason: .maxTurns))
        }
        continuation.finish()
    }

    // MARK: - Request Building

    private func buildRequest() -> MessagesRequest {
        let systemBlocks: [SystemBlock]?
        if let prompt = configuration.systemPrompt {
            systemBlocks = [SystemBlock(text: prompt, cacheControl: CacheControl())]
        } else {
            systemBlocks = nil
        }

        let toolDefs: [ToolDefinition]? = tools.isEmpty ? nil : tools.values.map { tool in
            ToolDefinition(
                name: tool.name,
                description: tool.description,
                inputSchema: jsonValueFromSchema(tool.inputSchema)
            )
        }

        // Scale up max_tokens on recovery attempts (exponential: 1x → 2x → 4x → 8x)
        let maxTokens = effectiveMaxTokens()

        // Extended thinking config
        let thinking: ThinkingConfig? = configuration.thinkingEnabled
            ? ThinkingConfig(budgetTokens: configuration.thinkingBudgetTokens)
            : nil

        // Server-side context compression
        let contextManagement: ContextManagementConfig? = configuration.contextCompressionEnabled
            ? ContextManagementConfig()
            : nil

        // API rejects temperature when thinking is enabled
        let temperature: Double? = configuration.thinkingEnabled ? nil : configuration.temperature

        return MessagesRequest(
            model: configuration.model,
            maxTokens: maxTokens,
            messages: state.messages,
            system: systemBlocks,
            tools: toolDefs,
            stream: true,
            temperature: temperature,
            topP: configuration.topP,
            thinking: thinking,
            contextManagement: contextManagement
        )
    }

    /// Convert an InputSchema to a JSONValue for the API request.
    private func jsonValueFromSchema(_ schema: InputSchema) -> JSONValue {
        return Self.anyToJSONValue(schema.value)
    }

    private static func anyToJSONValue(_ value: Any) -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let int as Int:
            return .integer(int)
        case let double as Double:
            return .number(double)
        case let bool as Bool:
            return .bool(bool)
        case let array as [Any]:
            return .array(array.map { anyToJSONValue($0) })
        case let dict as [String: Any]:
            return .object(dict.mapValues { anyToJSONValue($0) })
        default:
            return .null
        }
    }

    /// Returns the effective max_tokens for the current recovery attempt.
    /// Exponential escalation: base → 2x → 4x → 8x, capped at sensible limits.
    private func effectiveMaxTokens() -> Int {
        let base = configuration.maxTokens
        switch state.maxOutputTokensRecoveryCount {
        case 0: return base
        case 1: return min(base * 2, 16384)
        case 2: return min(base * 4, 32768)
        case 3: return min(base * 8, 65536)
        default: return base  // shouldn't reach here
        }
    }

    // MARK: - Stream Response

    /// Result of streaming a single API response turn.
    private struct StreamedResponse {
        let contentBlocks: [ContentBlock]
        let stopReason: String?
    }

    /// Stream an API response, yielding delta events and collecting content blocks.
    private func streamResponse(
        request: MessagesRequest,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async -> Result<StreamedResponse, AgentError> {
        // Track in-progress content blocks by index
        var blocksByIndex: [Int: InProgressBlock] = [:]
        var stopReason: String?

        let eventStream = await client.stream(request: request)

        for await event in eventStream {
            if state.isCancelled {
                return .failure(.cancelled)
            }

            switch event {
            case .messageStart(let msg):
                continuation.yield(.usage(
                    inputTokens: msg.message.usage.inputTokens,
                    outputTokens: msg.message.usage.outputTokens,
                    cacheRead: msg.message.usage.cacheReadInputTokens,
                    cacheCreation: msg.message.usage.cacheCreationInputTokens
                ))

            case .contentBlockStart(let start):
                let index = start.index
                let info = start.contentBlock

                switch info.type {
                case "text":
                    blocksByIndex[index] = .text(accumulated: info.text ?? "")
                case "tool_use":
                    let id = info.id ?? ""
                    let name = info.name ?? ""
                    blocksByIndex[index] = .toolUse(id: id, name: name, inputJSON: "")
                    continuation.yield(.toolUseStart(id: id, name: name))
                case "thinking":
                    blocksByIndex[index] = .thinking(accumulated: info.thinking ?? "", signature: info.signature)
                default:
                    break
                }

            case .contentBlockDelta(let delta):
                let index = delta.index

                switch delta.delta {
                case .textDelta(let text):
                    if case .text(var accumulated) = blocksByIndex[index] {
                        accumulated += text
                        blocksByIndex[index] = .text(accumulated: accumulated)
                    }
                    continuation.yield(.textDelta(text))

                case .inputJSONDelta(let json):
                    if case .toolUse(let id, let name, var inputJSON) = blocksByIndex[index] {
                        inputJSON += json
                        blocksByIndex[index] = .toolUse(id: id, name: name, inputJSON: inputJSON)
                        continuation.yield(.toolUseInput(id: id, partialJSON: json))
                    }

                case .thinkingDelta(let thinking):
                    if case .thinking(var accumulated, let sig) = blocksByIndex[index] {
                        accumulated += thinking
                        blocksByIndex[index] = .thinking(accumulated: accumulated, signature: sig)
                    }
                    continuation.yield(.thinkingDelta(thinking))
                }

            case .contentBlockStop(let stop):
                // Capture signature for thinking blocks (cryptographically signed by API)
                if let sig = stop.signature,
                   case .thinking(let accumulated, _) = blocksByIndex[stop.index] {
                    blocksByIndex[stop.index] = .thinking(accumulated: accumulated, signature: sig)
                }

            case .messageDelta(let delta):
                stopReason = delta.delta.stopReason
                continuation.yield(.usage(
                    inputTokens: 0,
                    outputTokens: delta.usage.outputTokens,
                    cacheRead: nil,
                    cacheCreation: nil
                ))

            case .messageStop:
                break

            case .ping:
                break

            case .error(let err):
                return .failure(.apiError(statusCode: 0, message: err.message))
            }
        }

        // Build final content blocks from accumulated data, sorted by index
        let sortedIndices = blocksByIndex.keys.sorted()
        let contentBlocks: [ContentBlock] = sortedIndices.compactMap { index in
            guard let block = blocksByIndex[index] else { return nil }
            switch block {
            case .text(let accumulated):
                return .text(TextBlock(text: accumulated))
            case .toolUse(let id, let name, let inputJSON):
                let input = Self.parseToolInput(inputJSON)
                return .toolUse(ToolUseBlock(id: id, name: name, input: input))
            case .thinking(let accumulated, let signature):
                return .thinking(ThinkingBlock(thinking: accumulated, signature: signature))
            }
        }

        return .success(StreamedResponse(contentBlocks: contentBlocks, stopReason: stopReason))
    }

    /// In-progress content block being accumulated from SSE deltas.
    private enum InProgressBlock {
        case text(accumulated: String)
        case toolUse(id: String, name: String, inputJSON: String)
        case thinking(accumulated: String, signature: String?)
    }

    // MARK: - Tool Input Parsing

    /// Parse accumulated JSON string into a `[String: JSONValue]` dictionary.
    private static func parseToolInput(_ jsonString: String) -> [String: JSONValue] {
        guard !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8) else {
            return [:]
        }

        do {
            let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
            return decoded
        } catch {
            return [:]
        }
    }

    /// Convert `[String: JSONValue]` into `[String: Any]` for tool execution.
    private static func jsonValueToAny(_ dict: [String: JSONValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            result[key] = jsonValueElementToAny(value)
        }
        return result
    }

    private static func jsonValueElementToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let d): return d
        case .integer(let i): return i
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { jsonValueElementToAny($0) }
        case .object(let dict): return jsonValueToAny(dict)
        }
    }

    // MARK: - Tool Execution

    /// A tool call that passed permission and validation, ready to execute.
    private struct PreparedCall: Sendable {
        let toolUse: ToolUseBlock
        let tool: any AgentTool
        let input: SendableInputWrapper
        let isConcurrencySafe: Bool
    }

    /// Execute tool calls, dispatching concurrency-safe tools in parallel
    /// and serializing unsafe tools. Results are returned in the same order
    /// as the original `toolUseBlocks` (API requirement).
    private func executeTools(
        toolUseBlocks: [ToolUseBlock],
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async -> [ToolResultBlock] {
        let context = ToolContext(workingDirectory: configuration.workingDirectory)

        // 1. Permission & validation pre-flight for all tools (must be serial — touches actor state)
        var prepared: [(index: Int, call: PreparedCall)] = []
        var resultsByIndex: [Int: ToolResultBlock] = [:]

        for (index, toolUse) in toolUseBlocks.enumerated() {
            if state.isCancelled {
                resultsByIndex[index] = ToolResultBlock(
                    toolUseId: toolUse.id,
                    content: "Execution cancelled",
                    isError: true
                )
                continue
            }

            guard let tool = tools[toolUse.name] else {
                let result = ToolResultBlock(
                    toolUseId: toolUse.id,
                    content: "Unknown tool: \(toolUse.name)",
                    isError: true
                )
                resultsByIndex[index] = result
                continuation.yield(.toolResult(id: toolUse.id, output: result.content, isError: true))
                continue
            }

            let inputDict = Self.jsonValueToAny(toolUse.input)

            // Permission check — copy through nonisolated to satisfy Sendable
            let decision: ToolDecision
            if sessionApprovedTools.contains(toolUse.name) {
                decision = .approve
            } else if let callback = configuration.permissionCallback {
                let toolName = toolUse.name
                let sendableInput = SendableInputWrapper(inputDict)
                decision = await callback(toolName, sendableInput.value)
            } else {
                decision = .approve
            }

            switch decision {
            case .block(let reason):
                let result = ToolResultBlock(
                    toolUseId: toolUse.id,
                    content: "Permission denied: \(reason)",
                    isError: true
                )
                resultsByIndex[index] = result
                continuation.yield(.toolResult(id: toolUse.id, output: result.content, isError: true))
                continue
            case .approve:
                break
            case .approveForSession:
                sessionApprovedTools.insert(toolUse.name)
            }

            // Validate
            do {
                try tool.validate(input: inputDict, context: context)
            } catch {
                let result = ToolResultBlock(
                    toolUseId: toolUse.id,
                    content: "Validation error: \(error.localizedDescription)",
                    isError: true
                )
                resultsByIndex[index] = result
                continuation.yield(.toolResult(id: toolUse.id, output: result.content, isError: true))
                continue
            }

            prepared.append((
                index: index,
                call: PreparedCall(
                    toolUse: toolUse,
                    tool: tool,
                    input: SendableInputWrapper(inputDict),
                    isConcurrencySafe: tool.isConcurrencySafe
                )
            ))
        }

        // 2. Separate into parallel-safe and serial groups
        let safeCalls = prepared.filter { $0.call.isConcurrencySafe }
        let unsafeCalls = prepared.filter { !$0.call.isConcurrencySafe }

        // 3. Execute concurrency-safe tools in parallel via TaskGroup
        if !safeCalls.isEmpty {
            let safeResults = await withTaskGroup(
                of: (Int, ToolResultBlock).self,
                returning: [(Int, ToolResultBlock)].self
            ) { group in
                for (index, call) in safeCalls {
                    let capturedContext = context
                    group.addTask {
                        let result = await Self.executeSingleTool(
                            tool: call.tool,
                            toolUse: call.toolUse,
                            input: call.input,
                            context: capturedContext
                        )
                        return (index, result)
                    }
                }
                var collected: [(Int, ToolResultBlock)] = []
                for await pair in group {
                    collected.append(pair)
                }
                return collected
            }

            for (index, result) in safeResults {
                resultsByIndex[index] = result
                continuation.yield(.toolResult(
                    id: result.toolUseId,
                    output: result.content,
                    isError: result.isError ?? false
                ))
            }
        }

        // 4. Execute unsafe tools serially
        for (index, call) in unsafeCalls {
            if state.isCancelled {
                let result = ToolResultBlock(
                    toolUseId: call.toolUse.id,
                    content: "Execution cancelled",
                    isError: true
                )
                resultsByIndex[index] = result
                continue
            }

            let result = await Self.executeSingleTool(
                tool: call.tool,
                toolUse: call.toolUse,
                input: call.input,
                context: context
            )
            resultsByIndex[index] = result
            continuation.yield(.toolResult(
                id: result.toolUseId,
                output: result.content,
                isError: result.isError ?? false
            ))

            if result.isError == true {
                continuation.yield(.error(.toolExecutionFailed(
                    toolName: call.toolUse.name,
                    message: result.content
                )))
            }
        }

        // 5. Return results in original order
        return toolUseBlocks.enumerated().map { index, toolUse in
            resultsByIndex[index] ?? ToolResultBlock(
                toolUseId: toolUse.id,
                content: "Tool result missing (internal error)",
                isError: true
            )
        }
    }

    /// Execute a single tool call with timeout (stateless helper — safe to call from TaskGroup).
    private static func executeSingleTool(
        tool: any AgentTool,
        toolUse: ToolUseBlock,
        input: SendableInputWrapper,
        context: ToolContext
    ) async -> ToolResultBlock {
        let toolTimeout = tool.timeout
        do {
            let toolResult = try await withThrowingTaskGroup(of: ToolResult.self) { group in
                group.addTask {
                    try await tool.execute(input: input.value, context: context)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(toolTimeout * 1_000_000_000))
                    throw ToolError.timeout
                }
                guard let result = try await group.next() else {
                    throw ToolError.timeout
                }
                group.cancelAll()
                return result
            }
            return ToolResultBlock(
                toolUseId: toolUse.id,
                content: toolResult.content,
                isError: toolResult.isError ? true : nil
            )
        } catch ToolError.timeout {
            return ToolResultBlock(
                toolUseId: toolUse.id,
                content: "Tool execution timed out after \(Int(toolTimeout))s",
                isError: true
            )
        } catch {
            return ToolResultBlock(
                toolUseId: toolUse.id,
                content: "Tool execution failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

}

// MARK: - SendableInputWrapper

/// Wraps a `[String: Any]` dictionary so it can cross actor isolation boundaries.
/// The dictionary is deep-copied at init time and never mutated, making `@unchecked Sendable` safe.
private struct SendableInputWrapper: @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) {
        self.value = value
    }
}