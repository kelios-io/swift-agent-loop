import Testing
import Foundation
@testable import SwiftAgentLoop

// MARK: - SSE Helpers (duplicated from AgentLoopTests for isolation)

private func messageStart() -> SSEEvent {
    .messageStart(MessageStartEvent(
        type: "message_start",
        message: MessageStartMessage(
            id: "msg_sub",
            type: "message",
            role: "assistant",
            model: "claude-haiku-4-5-20251001",
            usage: Usage(inputTokens: 5, outputTokens: 3, cacheReadInputTokens: nil, cacheCreationInputTokens: nil)
        )
    ))
}

private func textStart(index: Int) -> SSEEvent {
    .contentBlockStart(ContentBlockStartEvent(
        type: "content_block_start",
        index: index,
        contentBlock: ContentBlockInfo(type: "text")
    ))
}

private func textDelta(index: Int, text: String) -> SSEEvent {
    .contentBlockDelta(ContentBlockDeltaEvent(
        type: "content_block_delta",
        index: index,
        delta: .textDelta(text: text)
    ))
}

private func blockStop(index: Int) -> SSEEvent {
    .contentBlockStop(ContentBlockStopEvent(type: "content_block_stop", index: index))
}

private func messageDelta(stopReason: String) -> SSEEvent {
    .messageDelta(MessageDeltaEvent(
        type: "message_delta",
        delta: MessageDelta(stopReason: stopReason),
        usage: DeltaUsage(outputTokens: 5)
    ))
}

private func messageStop() -> SSEEvent {
    .messageStop
}

/// Simple text response sequence.
private func simpleTextResponse(_ text: String) -> [SSEEvent] {
    [
        messageStart(),
        textStart(index: 0),
        textDelta(index: 0, text: text),
        blockStop(index: 0),
        messageDelta(stopReason: "end_turn"),
        messageStop(),
    ]
}

// MARK: - Tests

@Suite("SubagentTool")
struct SubagentToolTests {

    // MARK: - 1. Simple execution

    @Test("Subagent returns text output as tool result")
    func simpleExecution() async throws {
        let mock = MockClient(responses: [simpleTextResponse("Hello from subagent")])
        let tool = SubagentTool(client: mock, parentModel: "claude-sonnet-4-6")
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)

        let result = try await tool.execute(
            input: ["prompt": "Say hello", "subagent_type": "general"],
            context: context
        )
        #expect(result.isError == false)
        #expect(result.content.contains("Hello from subagent"))
    }

    // MARK: - 2. Explore type

    @Test("Explore subagent uses read-only tools")
    func exploreType() {
        let definition = SubagentDefinition.explore()
        let tools = definition.makeTools()
        let toolNames = Set(tools.map(\.name))
        #expect(toolNames == Set(["Read", "Glob", "Grep"]))
        #expect(definition.model == "claude-haiku-4-5-20251001")
        #expect(definition.maxTurns == 20)
    }

    // MARK: - 3. Plan type

    @Test("Plan subagent inherits parent model and has read-only tools")
    func planType() {
        let definition = SubagentDefinition.plan(parentModel: "claude-opus-4-6")
        let tools = definition.makeTools()
        let toolNames = Set(tools.map(\.name))
        #expect(toolNames == Set(["Read", "Glob", "Grep"]))
        #expect(definition.model == "claude-opus-4-6")
    }

    // MARK: - 4. General type has all tools

    @Test("General subagent has all file tools")
    func generalType() {
        let definition = SubagentDefinition.general(parentModel: "claude-sonnet-4-6")
        let tools = definition.makeTools()
        let toolNames = Set(tools.map(\.name))
        #expect(toolNames == Set(["Read", "Write", "Edit", "Bash", "Glob", "Grep"]))
    }

    // MARK: - 5. Depth enforcement

    @Test("Subagent tool list does not include Agent (no nested spawning)")
    func depthEnforcement() {
        // All subagent types must exclude the Agent tool
        for def in [
            SubagentDefinition.general(parentModel: "m"),
            SubagentDefinition.explore(),
            SubagentDefinition.plan(parentModel: "m"),
        ] {
            let tools = def.makeTools()
            let hasAgent = tools.contains { $0.name == "Agent" }
            #expect(!hasAgent, "Subagent type '\(def.name)' should not include Agent tool")
        }
    }

    // MARK: - 6. Unknown type returns error

    @Test("Invalid subagent type fails validation")
    func unknownTypeValidation() throws {
        let mock = MockClient(responses: [])
        let tool = SubagentTool(client: mock, parentModel: "claude-sonnet-4-6")
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)

        #expect(throws: ToolError.self) {
            try tool.validate(
                input: ["prompt": "test", "subagent_type": "invalid"],
                context: context
            )
        }
    }

    // MARK: - 7. Missing prompt validation

    @Test("Missing prompt fails validation")
    func missingPromptValidation() throws {
        let mock = MockClient(responses: [])
        let tool = SubagentTool(client: mock, parentModel: "claude-sonnet-4-6")
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)

        #expect(throws: ToolError.self) {
            try tool.validate(input: [:], context: context)
        }
    }

    // MARK: - 8. Subagent with no output

    @Test("Subagent with no text output returns placeholder")
    func noOutputPlaceholder() async throws {
        // Response with only end_turn, no text blocks
        let events: [SSEEvent] = [
            messageStart(),
            messageDelta(stopReason: "end_turn"),
            messageStop(),
        ]
        let mock = MockClient(responses: [events])
        let tool = SubagentTool(client: mock, parentModel: "claude-sonnet-4-6")
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)

        let result = try await tool.execute(
            input: ["prompt": "Do nothing"],
            context: context
        )
        #expect(result.isError == false)
        #expect(result.content.contains("no output"))
    }
}
