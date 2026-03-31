import Foundation
@testable import SwiftAgentLoop

print("SwiftAgentLoop Benchmark Suite")
print("==============================\n")

// MARK: - Setup

let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
let hasAPIKey = apiKey != nil && !apiKey!.isEmpty

print("API key: \(hasAPIKey ? "available (e2e benchmarks enabled)" : "not set (e2e benchmarks skipped)")")

// Create file tree fixture for tool benchmarks
print("\nSetting up file tree fixture (10K files)...")
let fixture = try FileTreeFixture.create()
let context = ToolContext(workingDirectory: fixture.rootDir)
print("Fixture ready at: \(fixture.rootDir.path)\n")

// MARK: - 1. Cold Start

print("Running benchmarks...\n")

await BenchmarkHarness.measureOnce(name: "cold_start") {
    let config = AgentConfiguration(
        model: "claude-sonnet-4-6",
        tools: [ReadTool(), WriteTool(), EditTool(), BashTool(), GlobTool(), GrepTool()]
    )
    // MockClient to avoid real API call
    let mockClient = BenchmarkMockClient()
    let _ = AgentLoop(client: mockClient, configuration: config)
}

// MARK: - 2. Memory Baseline

let baselineMemory = residentMemoryBytes()
BenchmarkHarness.record(
    name: "memory_baseline",
    value: formatBytes(baselineMemory),
    unit: "resident"
)

// MARK: - 3. Memory Peak Session (mock 20-turn)

do {
    var peakMemory: UInt64 = 0
    let mockClient = BenchmarkMockClient.forMultiTurn(turns: 20)
    let config = AgentConfiguration(
        model: "claude-sonnet-4-6",
        maxTurns: 25,
        tools: [MockBenchTool()],
        workingDirectory: fixture.rootDir
    )
    let loop = AgentLoop(client: mockClient, configuration: config)
    let stream = await loop.run(prompt: "Run 20 turns")
    for await _ in stream {
        let mem = residentMemoryBytes()
        if mem > peakMemory { peakMemory = mem }
    }
    BenchmarkHarness.record(
        name: "memory_peak_session",
        value: formatBytes(peakMemory),
        unit: "peak resident (20 turns)"
    )
}

// MARK: - 4. SSE Parse Throughput

do {
    let eventCount = 10_000
    let sseData = MockSSEData.generateEvents(count: eventCount)
    let bytes = Array(sseData)

    await BenchmarkHarness.measureOnce(name: "sse_parse_throughput") {
        let source = AsyncStream<UInt8> { continuation in
            for byte in bytes {
                continuation.yield(byte)
            }
            continuation.finish()
        }
        let parser = SSEParser(source: source)
        var count = 0
        for await _ in parser.events() {
            count += 1
        }
    }
    let totalEvents = eventCount + 4 // +start, block_start, block_stop, delta, stop
    BenchmarkHarness.record(
        name: "sse_parse_events",
        value: "\(totalEvents) events in \(formatBytes(UInt64(sseData.count))) of SSE data",
        unit: ""
    )
}

// MARK: - 5. Tool Roundtrip: Read

let readTool = ReadTool()
try await BenchmarkHarness.measure(name: "tool_roundtrip_read", iterations: 100) {
    let _ = try await readTool.execute(
        input: ["file_path": fixture.singleFilePath],
        context: context
    )
}

// MARK: - 6. Tool Roundtrip: Edit

let editTool = EditTool()
// Write a file to edit, reset each iteration
let editFilePath = fixture.rootDir.appendingPathComponent("edit_bench.txt").path
try await BenchmarkHarness.measure(name: "tool_roundtrip_edit", iterations: 100) {
    // Reset file
    try "Hello world\nSecond line\nThird line\n".write(
        toFile: editFilePath, atomically: false, encoding: .utf8
    )
    let _ = try await editTool.execute(
        input: ["file_path": editFilePath, "old_string": "Second line", "new_string": "Replaced line"],
        context: context
    )
}

// MARK: - 7. Tool Roundtrip: Glob

let globTool = GlobTool()
try await BenchmarkHarness.measure(name: "tool_roundtrip_glob", iterations: 100) {
    let _ = try await globTool.execute(
        input: ["pattern": "**/*.swift"],
        context: context
    )
}

// MARK: - 8. Tool Roundtrip: Grep

let grepTool = GrepTool()
try await BenchmarkHarness.measure(name: "tool_roundtrip_grep", iterations: 100) {
    let _ = try await grepTool.execute(
        input: ["pattern": "process_.*\\(\\)", "output_mode": "files_with_matches"],
        context: context
    )
}

// MARK: - 9. Tool Roundtrip: Bash

let bashTool = BashTool()
try await BenchmarkHarness.measure(name: "tool_roundtrip_bash", iterations: 100) {
    let _ = try await bashTool.execute(
        input: ["command": "echo hello"],
        context: context
    )
}

// MARK: - 10 & 11. E2E (API key required)

if let key = apiKey, !key.isEmpty {
    print("\n  Running E2E benchmarks (real API)...")

    let transport = NativeTransport.withDefaultTools(apiKey: key, model: "claude-haiku-4-5-20251001")

    await BenchmarkHarness.measureOnce(name: "e2e_simple_task") {
        let stream = await transport.start(
            prompt: "What is 2+2? Reply with just the number.",
            systemPrompt: "Be concise.",
            workingDirectory: fixture.rootDir
        )
        for await event in stream {
            if case .done = event { break }
        }
    }

    await BenchmarkHarness.measureOnce(name: "e2e_multi_tool_task") {
        let stream = await transport.start(
            prompt: "Read the file at \(fixture.singleFilePath), count the lines, then tell me how many lines it has.",
            systemPrompt: "Use the Read tool to read the file. Be concise.",
            workingDirectory: fixture.rootDir
        )
        for await event in stream {
            if case .done = event { break }
        }
    }
} else {
    print("\n  Skipping E2E benchmarks (set ANTHROPIC_API_KEY to enable)")
}

// MARK: - Cleanup & Report

fixture.cleanup()
print("")
BenchmarkHarness.printMarkdownTable()

// MARK: - Mock Helpers

/// Minimal mock client for benchmarks — returns a simple text response.
final class BenchmarkMockClient: MessageStreaming, @unchecked Sendable {
    private var responses: [[SSEEvent]]
    private var callIndex = 0

    init() {
        self.responses = [BenchmarkMockClient.simpleEndTurn()]
    }

    init(responses: [[SSEEvent]]) {
        self.responses = responses
    }

    /// Create a mock that returns tool_use then end_turn for N turns.
    static func forMultiTurn(turns: Int) -> BenchmarkMockClient {
        var responses: [[SSEEvent]] = []
        for i in 0..<turns {
            responses.append(toolUseTurn(toolId: "tool_\(i)"))
        }
        responses.append(simpleEndTurn())
        return BenchmarkMockClient(responses: responses)
    }

    func stream(request: MessagesRequest) async -> AsyncStream<SSEEvent> {
        let events: [SSEEvent]
        if callIndex < responses.count {
            events = responses[callIndex]
            callIndex += 1
        } else {
            events = BenchmarkMockClient.simpleEndTurn()
        }
        return AsyncStream { c in
            for e in events { c.yield(e) }
            c.finish()
        }
    }

    private static func simpleEndTurn() -> [SSEEvent] {
        [
            .messageStart(MessageStartEvent(
                type: "message_start",
                message: MessageStartMessage(id: "msg", type: "message", role: "assistant", model: "m",
                    usage: Usage(inputTokens: 10, outputTokens: 5, cacheReadInputTokens: nil, cacheCreationInputTokens: nil))
            )),
            .contentBlockStart(ContentBlockStartEvent(
                type: "content_block_start", index: 0,
                contentBlock: ContentBlockInfo(type: "text")
            )),
            .contentBlockDelta(ContentBlockDeltaEvent(
                type: "content_block_delta", index: 0, delta: .textDelta(text: "Done.")
            )),
            .contentBlockStop(ContentBlockStopEvent(type: "content_block_stop", index: 0)),
            .messageDelta(MessageDeltaEvent(
                type: "message_delta", delta: MessageDelta(stopReason: "end_turn"),
                usage: DeltaUsage(outputTokens: 5)
            )),
            .messageStop,
        ]
    }

    private static func toolUseTurn(toolId: String) -> [SSEEvent] {
        [
            .messageStart(MessageStartEvent(
                type: "message_start",
                message: MessageStartMessage(id: "msg", type: "message", role: "assistant", model: "m",
                    usage: Usage(inputTokens: 10, outputTokens: 5, cacheReadInputTokens: nil, cacheCreationInputTokens: nil))
            )),
            .contentBlockStart(ContentBlockStartEvent(
                type: "content_block_start", index: 0,
                contentBlock: ContentBlockInfo(type: "tool_use", id: toolId, name: "BenchTool")
            )),
            .contentBlockDelta(ContentBlockDeltaEvent(
                type: "content_block_delta", index: 0, delta: .inputJSONDelta(partialJSON: "{}")
            )),
            .contentBlockStop(ContentBlockStopEvent(type: "content_block_stop", index: 0)),
            .messageDelta(MessageDeltaEvent(
                type: "message_delta", delta: MessageDelta(stopReason: "tool_use"),
                usage: DeltaUsage(outputTokens: 5)
            )),
            .messageStop,
        ]
    }
}

/// Mock tool for multi-turn session benchmarks.
struct MockBenchTool: AgentTool {
    let name = "BenchTool"
    let description = "Mock tool for benchmarks"
    var inputSchema: InputSchema { InputSchema([:]) }
    let isReadOnly = true
    let isConcurrencySafe = true
    func validate(input: [String: Any], context: ToolContext) throws {}
    func execute(input: [String: Any], context: ToolContext) async throws -> ToolResult {
        .success("ok")
    }
}
