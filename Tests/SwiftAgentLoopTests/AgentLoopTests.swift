import Testing
import Foundation
@testable import SwiftAgentLoop

// MARK: - Atomic Counter

/// Thread-safe counter for use in Sendable closures (tests only).
final class AtomicCounter: @unchecked Sendable {
    private var _value: Int
    private let lock = NSLock()

    init(_ initial: Int = 0) { _value = initial }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
        return _value
    }
}

// MARK: - Mock Client

/// A mock `MessageStreaming` client that returns predefined SSE event sequences.
/// Each call to `stream(request:)` pops the next response from the queue.
final class MockClient: MessageStreaming, @unchecked Sendable {
    private var responses: [[SSEEvent]]
    private var callIndex = 0

    init(responses: [[SSEEvent]]) {
        self.responses = responses
    }

    func stream(request: MessagesRequest) async -> AsyncStream<SSEEvent> {
        let events: [SSEEvent]
        if callIndex < responses.count {
            events = responses[callIndex]
            callIndex += 1
        } else {
            events = []
        }
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

// MARK: - Mock Tool

struct MockTool: AgentTool {
    let name: String
    let description: String = "A mock tool for testing"
    var inputSchema: InputSchema { InputSchema([:]) }
    let isReadOnly: Bool = true
    let isConcurrencySafe: Bool = true
    var handler: @Sendable ([String: Any]) async -> ToolResult = { _ in .success("mock result") }

    func validate(input: [String: Any], context: ToolContext) throws {}

    func execute(input: [String: Any], context: ToolContext) async throws -> ToolResult {
        await handler(input)
    }
}

// MARK: - SSE Event Helpers

/// Helper to build common SSE event sequences for the mock client.
private func messageStartEvent() -> SSEEvent {
    .messageStart(MessageStartEvent(
        type: "message_start",
        message: MessageStartMessage(
            id: "msg_test",
            type: "message",
            role: "assistant",
            model: "claude-sonnet-4-20250514",
            usage: Usage(
                inputTokens: 10,
                outputTokens: 5,
                cacheReadInputTokens: nil,
                cacheCreationInputTokens: nil
            )
        )
    ))
}

private func textBlockStart(index: Int, text: String = "") -> SSEEvent {
    .contentBlockStart(ContentBlockStartEvent(
        type: "content_block_start",
        index: index,
        contentBlock: ContentBlockInfo(type: "text", id: nil, name: nil, text: text, thinking: nil)
    ))
}

private func textDelta(index: Int, text: String) -> SSEEvent {
    .contentBlockDelta(ContentBlockDeltaEvent(
        type: "content_block_delta",
        index: index,
        delta: .textDelta(text: text)
    ))
}

private func toolUseBlockStart(index: Int, id: String, name: String) -> SSEEvent {
    .contentBlockStart(ContentBlockStartEvent(
        type: "content_block_start",
        index: index,
        contentBlock: ContentBlockInfo(type: "tool_use", id: id, name: name, text: nil, thinking: nil)
    ))
}

private func inputJSONDelta(index: Int, json: String) -> SSEEvent {
    .contentBlockDelta(ContentBlockDeltaEvent(
        type: "content_block_delta",
        index: index,
        delta: .inputJSONDelta(partialJSON: json)
    ))
}

private func contentBlockStop(index: Int) -> SSEEvent {
    .contentBlockStop(ContentBlockStopEvent(type: "content_block_stop", index: index))
}

private func messageDelta(stopReason: String) -> SSEEvent {
    .messageDelta(MessageDeltaEvent(
        type: "message_delta",
        delta: MessageDelta(stopReason: stopReason),
        usage: DeltaUsage(outputTokens: 10)
    ))
}

private let messageStop: SSEEvent = .messageStop

// MARK: - Convenience: full response sequences

/// A simple text-only response that ends the turn.
private func textResponse(_ text: String) -> [SSEEvent] {
    [
        messageStartEvent(),
        textBlockStart(index: 0),
        textDelta(index: 0, text: text),
        contentBlockStop(index: 0),
        messageDelta(stopReason: "end_turn"),
        messageStop,
    ]
}

/// A response that calls a tool, then stops with tool_use.
private func toolUseResponse(toolId: String, toolName: String, inputJSON: String) -> [SSEEvent] {
    [
        messageStartEvent(),
        toolUseBlockStart(index: 0, id: toolId, name: toolName),
        inputJSONDelta(index: 0, json: inputJSON),
        contentBlockStop(index: 0),
        messageDelta(stopReason: "tool_use"),
        messageStop,
    ]
}

/// A response that hits max_tokens (no end_turn).
private func maxTokensResponse(_ text: String) -> [SSEEvent] {
    [
        messageStartEvent(),
        textBlockStart(index: 0),
        textDelta(index: 0, text: text),
        contentBlockStop(index: 0),
        messageDelta(stopReason: "max_tokens"),
        messageStop,
    ]
}

// MARK: - Helper to collect events

private func collectEvents(from stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

// MARK: - Tests

@Suite("AgentLoop")
struct AgentLoopTests {

    // MARK: 1. Single text response (no tools)

    @Test("Single text response yields textDelta then done(completed)")
    func singleTextResponse() async throws {
        let client = MockClient(responses: [textResponse("Hello, world!")])
        let config = AgentConfiguration(
            maxTokens: 1024,
            maxTurns: 10,
            tools: []
        )
        let loop = AgentLoop(client: client, configuration: config)
        let events = await collectEvents(from: await loop.run(prompt: "Hi"))

        // Should contain at least one textDelta and a done(completed)
        let textDeltas = events.compactMap { event -> String? in
            if case .textDelta(let text) = event { return text }
            return nil
        }
        #expect(textDeltas == ["Hello, world!"])

        let doneEvents = events.compactMap { event -> StopReason? in
            if case .done(let reason) = event { return reason }
            return nil
        }
        #expect(doneEvents.count == 1)
        #expect(doneEvents.first == .completed)
    }

    // MARK: 2. Single tool turn

    @Test("Single tool turn executes tool and returns result")
    func singleToolTurn() async throws {
        let client = MockClient(responses: [
            // Turn 1: model calls the tool
            toolUseResponse(toolId: "tu_1", toolName: "mock_tool", inputJSON: "{}"),
            // Turn 2: model responds with text after seeing tool result
            textResponse("Done!"),
        ])

        let tool = MockTool(name: "mock_tool") { _ in .success("tool output") }
        let config = AgentConfiguration(
            maxTokens: 1024,
            maxTurns: 10,
            tools: [tool]
        )
        let loop = AgentLoop(client: client, configuration: config)
        let events = await collectEvents(from: await loop.run(prompt: "Use the tool"))

        // Should have toolUseStart, toolResult, turnComplete, textDelta, done
        let toolStarts = events.compactMap { e -> String? in
            if case .toolUseStart(_, let name) = e { return name }
            return nil
        }
        #expect(toolStarts == ["mock_tool"])

        let toolResults = events.compactMap { e -> String? in
            if case .toolResult(_, let output, _) = e { return output }
            return nil
        }
        #expect(toolResults == ["tool output"])

        let turnCompletes = events.compactMap { e -> Int? in
            if case .turnComplete(let n) = e { return n }
            return nil
        }
        #expect(turnCompletes == [1])

        // Final done
        let doneReasons = events.compactMap { e -> StopReason? in
            if case .done(let r) = e { return r }
            return nil
        }
        #expect(doneReasons == [.completed])
    }

    // MARK: 3. Multi-turn conversation

    @Test("Multi-turn: two tool calls then final text")
    func multiTurnConversation() async throws {
        let client = MockClient(responses: [
            toolUseResponse(toolId: "tu_1", toolName: "mock_tool", inputJSON: "{}"),
            toolUseResponse(toolId: "tu_2", toolName: "mock_tool", inputJSON: "{}"),
            textResponse("All done."),
        ])

        let callCount = AtomicCounter()
        let tool = MockTool(name: "mock_tool") { @Sendable _ in
            let n = callCount.increment()
            return .success("result \(n)")
        }
        let config = AgentConfiguration(
            maxTokens: 1024,
            maxTurns: 10,
            tools: [tool]
        )
        let loop = AgentLoop(client: client, configuration: config)
        let events = await collectEvents(from: await loop.run(prompt: "Do two things"))

        let turnCompletes = events.compactMap { e -> Int? in
            if case .turnComplete(let n) = e { return n }
            return nil
        }
        #expect(turnCompletes == [1, 2])

        let doneReasons = events.compactMap { e -> StopReason? in
            if case .done(let r) = e { return r }
            return nil
        }
        #expect(doneReasons == [.completed])
    }

    // MARK: 4. Max turns guard

    @Test("Max turns guard stops the loop")
    func maxTurnsGuard() async throws {
        // Always returns tool_use — loop should stop after 2 turns
        let client = MockClient(responses: [
            toolUseResponse(toolId: "tu_1", toolName: "mock_tool", inputJSON: "{}"),
            toolUseResponse(toolId: "tu_2", toolName: "mock_tool", inputJSON: "{}"),
            toolUseResponse(toolId: "tu_3", toolName: "mock_tool", inputJSON: "{}"),
        ])

        let tool = MockTool(name: "mock_tool")
        let config = AgentConfiguration(
            maxTokens: 1024,
            maxTurns: 2,
            tools: [tool]
        )
        let loop = AgentLoop(client: client, configuration: config)
        let events = await collectEvents(from: await loop.run(prompt: "Loop forever"))

        let doneReasons = events.compactMap { e -> StopReason? in
            if case .done(let r) = e { return r }
            return nil
        }
        #expect(doneReasons == [.maxTurns])

        let turnCompletes = events.compactMap { e -> Int? in
            if case .turnComplete(let n) = e { return n }
            return nil
        }
        #expect(turnCompletes.count == 2)
    }

    // MARK: 5. Permission blocking

    @Test("Permission callback blocking yields error tool result")
    func permissionBlocking() async throws {
        let client = MockClient(responses: [
            toolUseResponse(toolId: "tu_1", toolName: "mock_tool", inputJSON: "{}"),
            textResponse("Blocked, understood."),
        ])

        let tool = MockTool(name: "mock_tool")
        let permissionCallback: PermissionCallback = { @Sendable name, _ in
            return .block(reason: "Not allowed in tests")
        }
        let config = AgentConfiguration(
            maxTokens: 1024,
            maxTurns: 10,
            tools: [tool],
            permissionCallback: permissionCallback
        )
        let loop = AgentLoop(client: client, configuration: config)
        let events = await collectEvents(from: await loop.run(prompt: "Use tool"))

        let toolResults = events.compactMap { e -> (String, Bool)? in
            if case .toolResult(_, let output, let isError) = e {
                return (output, isError)
            }
            return nil
        }
        #expect(toolResults.count == 1)
        #expect(toolResults.first?.0.contains("Permission denied") == true)
        #expect(toolResults.first?.1 == true)
    }

    // MARK: 6. Cancellation

    @Test("Cancellation stops the loop with aborted")
    func cancellation() async throws {
        // First response calls a tool; while the tool executes we cancel
        let client = MockClient(responses: [
            toolUseResponse(toolId: "tu_1", toolName: "slow_tool", inputJSON: "{}"),
            textResponse("Should not reach here"),
        ])

        // Create a slow tool that gives us time to cancel
        let tool = MockTool(name: "slow_tool") { @Sendable _ in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            return .success("slow result")
        }
        let config = AgentConfiguration(
            maxTokens: 1024,
            maxTurns: 10,
            tools: [tool]
        )
        let loop = AgentLoop(client: client, configuration: config)
        let stream = await loop.run(prompt: "Do something slow")

        // Collect events with a cancel after a short delay
        var events: [AgentEvent] = []
        let cancelTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms — cancel before tool finishes
            await loop.cancel()
        }

        for await event in stream {
            events.append(event)
        }
        cancelTask.cancel()

        let doneReasons = events.compactMap { e -> StopReason? in
            if case .done(let r) = e { return r }
            return nil
        }
        #expect(doneReasons.contains(.aborted))
    }

    // MARK: 7. Max tokens recovery

    @Test("Max tokens triggers retry then succeeds on end_turn")
    func maxTokensRecovery() async throws {
        let client = MockClient(responses: [
            // First attempt hits max_tokens
            maxTokensResponse("partial"),
            // Retry succeeds with end_turn
            textResponse("Complete response"),
        ])

        let config = AgentConfiguration(
            maxTokens: 1024,
            maxTurns: 10,
            tools: []
        )
        let loop = AgentLoop(client: client, configuration: config)
        let events = await collectEvents(from: await loop.run(prompt: "Write something long"))

        let textDeltas = events.compactMap { e -> String? in
            if case .textDelta(let t) = e { return t }
            return nil
        }
        // Should have text from both the truncated response and the retry
        #expect(textDeltas.contains("partial"))
        #expect(textDeltas.contains("Complete response"))

        let doneReasons = events.compactMap { e -> StopReason? in
            if case .done(let r) = e { return r }
            return nil
        }
        #expect(doneReasons == [.completed])
    }

    // MARK: 8. Max tokens exhaustion (exceeds 3 retries)

    @Test("Max tokens exhaustion after 4 consecutive max_tokens responses")
    func maxTokensExhaustion() async throws {
        let client = MockClient(responses: [
            maxTokensResponse("try 1"),
            maxTokensResponse("try 2"),
            maxTokensResponse("try 3"),
            maxTokensResponse("try 4"),
        ])

        let config = AgentConfiguration(
            maxTokens: 1024,
            maxTurns: 10,
            tools: []
        )
        let loop = AgentLoop(client: client, configuration: config)
        let events = await collectEvents(from: await loop.run(prompt: "Overflow"))

        let errors = events.compactMap { e -> AgentError? in
            if case .error(let err) = e { return err }
            return nil
        }
        // Should get maxTokensExhausted error
        let hasMaxTokensError = errors.contains { error in
            if case .maxTokensExhausted = error { return true }
            return false
        }
        #expect(hasMaxTokensError)
    }

    // MARK: 9. Unknown tool yields error

    @Test("Unknown tool name yields error result")
    func unknownToolError() async throws {
        let client = MockClient(responses: [
            toolUseResponse(toolId: "tu_1", toolName: "nonexistent_tool", inputJSON: "{}"),
            textResponse("OK"),
        ])

        let config = AgentConfiguration(
            maxTokens: 1024,
            maxTurns: 10,
            tools: [] // No tools registered
        )
        let loop = AgentLoop(client: client, configuration: config)
        let events = await collectEvents(from: await loop.run(prompt: "Call missing tool"))

        let toolResults = events.compactMap { e -> (String, Bool)? in
            if case .toolResult(_, let output, let isError) = e {
                return (output, isError)
            }
            return nil
        }
        #expect(toolResults.count == 1)
        #expect(toolResults.first?.0.contains("Unknown tool") == true)
        #expect(toolResults.first?.1 == true)
    }

    // MARK: 10. ApproveForSession persists across tool calls

    @Test("ApproveForSession skips callback on subsequent calls")
    func approveForSession() async throws {
        let client = MockClient(responses: [
            toolUseResponse(toolId: "tu_1", toolName: "mock_tool", inputJSON: "{}"),
            toolUseResponse(toolId: "tu_2", toolName: "mock_tool", inputJSON: "{}"),
            textResponse("Done"),
        ])

        let callbackCount = AtomicCounter()
        let tool = MockTool(name: "mock_tool")
        let permissionCallback: PermissionCallback = { @Sendable name, _ in
            callbackCount.increment()
            return .approveForSession
        }
        let config = AgentConfiguration(
            maxTokens: 1024,
            maxTurns: 10,
            tools: [tool],
            permissionCallback: permissionCallback
        )
        let loop = AgentLoop(client: client, configuration: config)
        _ = await collectEvents(from: await loop.run(prompt: "Use tool twice"))

        // Permission callback should only be called once — second call is auto-approved
        #expect(callbackCount.value == 1)
    }
}