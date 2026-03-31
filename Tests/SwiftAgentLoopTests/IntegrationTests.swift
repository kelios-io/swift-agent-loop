import Testing
import Foundation
@testable import SwiftAgentLoop

// MARK: - Helpers

/// Collect all events from an agent event stream.
private func collectEvents(from stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

/// Create a NativeTransport configured for integration testing.
private func makeTransport(
    apiKey: String,
    permissionCallback: PermissionCallback? = nil
) -> NativeTransport {
    let callback: PermissionCallback = permissionCallback ?? { @Sendable _, _ in .approve }
    return NativeTransport.withDefaultTools(
        apiKey: apiKey,
        model: "claude-haiku-4-5-20251001",
        permissionCallback: callback
    )
}

// MARK: - Integration Tests

/// Helper to get API key or skip the test.
private func requireAPIKey() throws -> String {
    guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
        throw SkipError()
    }
    return key
}

/// Error that causes Swift Testing to skip the test.
private struct SkipError: Error {}

@Suite("Integration Tests (requires ANTHROPIC_API_KEY)",
       .enabled(if: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil))
struct IntegrationTests {

    // MARK: 1. Single text response

    @Test("Single text response returns textDelta events and done(completed)")
    func singleTextResponse() async throws {
        let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!

        let transport = makeTransport(apiKey: apiKey)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-loop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let stream = await transport.start(
            prompt: "What is 2+2? Reply in one word.",
            systemPrompt: "You are a concise assistant. Reply in as few words as possible.",
            workingDirectory: tmpDir
        )
        let events = await collectEvents(from: stream)

        // Verify we got text deltas
        let textDeltas = events.compactMap { e -> String? in
            if case .textDelta(let t) = e { return t }
            return nil
        }
        #expect(!textDeltas.isEmpty, "Expected at least one textDelta event")

        let fullText = textDeltas.joined()
        #expect(fullText.lowercased().contains("4") || fullText.lowercased().contains("four"),
                "Expected response to contain '4' or 'four', got: \(fullText)")

        // Verify done(completed)
        let doneReasons = events.compactMap { e -> StopReason? in
            if case .done(let r) = e { return r }
            return nil
        }
        #expect(doneReasons.contains(.completed), "Expected done(completed)")
    }

    // MARK: 2. Single tool call (Read)

    @Test("ReadTool is invoked for file reading prompt")
    func singleToolCallRead() async throws {
        let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-loop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a temp file with known content
        let testFile = tmpDir.appendingPathComponent("test_input.txt")
        try "hello_from_integration_test".write(to: testFile, atomically: true, encoding: .utf8)

        let transport = makeTransport(apiKey: apiKey)
        let stream = await transport.start(
            prompt: "Read the file at \(testFile.path) and tell me exactly what it says. Use the Read tool.",
            systemPrompt: "You have file tools available. Use them when asked to read files.",
            workingDirectory: tmpDir
        )
        let events = await collectEvents(from: stream)

        // Verify ReadTool was invoked
        let toolStarts = events.compactMap { e -> String? in
            if case .toolUseStart(_, let name) = e { return name }
            return nil
        }
        #expect(toolStarts.contains("Read"), "Expected Read tool to be invoked, got: \(toolStarts)")

        // Verify tool result contains the file content
        let toolResults = events.compactMap { e -> String? in
            if case .toolResult(_, let output, let isError) = e, !isError { return output }
            return nil
        }
        let hasFileContent = toolResults.contains { $0.contains("hello_from_integration_test") }
        #expect(hasFileContent, "Expected tool result to contain file content")

        // Verify completed
        let doneReasons = events.compactMap { e -> StopReason? in
            if case .done(let r) = e { return r }
            return nil
        }
        #expect(doneReasons.contains(.completed))
    }

    // MARK: 3. Multi-turn (read then write)

    @Test("Multi-turn: read file then write reversed contents")
    func multiTurnReadThenWrite() async throws {
        let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-loop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let inputFile = tmpDir.appendingPathComponent("input.txt")
        let outputFile = tmpDir.appendingPathComponent("output.txt")
        try "ABCDEF".write(to: inputFile, atomically: true, encoding: .utf8)

        let transport = makeTransport(apiKey: apiKey)
        let stream = await transport.start(
            prompt: "Read the file at \(inputFile.path), then write the contents reversed (characters in reverse order) to \(outputFile.path). Use the Read and Write tools.",
            systemPrompt: "You have file tools. Use Read to read files and Write to write files. Do not explain, just do it.",
            workingDirectory: tmpDir
        )
        let events = await collectEvents(from: stream)

        // Verify both Read and Write tools were invoked
        let toolStarts = events.compactMap { e -> String? in
            if case .toolUseStart(_, let name) = e { return name }
            return nil
        }
        #expect(toolStarts.contains("Read"), "Expected Read tool invocation")
        #expect(toolStarts.contains("Write"), "Expected Write tool invocation")

        // Verify output file was created with reversed content
        if FileManager.default.fileExists(atPath: outputFile.path) {
            let output = try String(contentsOf: outputFile, encoding: .utf8)
            #expect(output.contains("FEDCBA"), "Expected reversed content 'FEDCBA', got: \(output)")
        }

        // Verify completed
        let doneReasons = events.compactMap { e -> StopReason? in
            if case .done(let r) = e { return r }
            return nil
        }
        #expect(!doneReasons.isEmpty, "Expected a done event")
    }

    // MARK: 4. Bash execution

    @Test("BashTool executes shell command")
    func bashExecution() async throws {
        let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-loop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let transport = makeTransport(apiKey: apiKey)
        let stream = await transport.start(
            prompt: "Run 'echo hello_integration_test' in bash and tell me the output. Use the Bash tool.",
            systemPrompt: "You have a Bash tool. Use it to run shell commands when asked.",
            workingDirectory: tmpDir
        )
        let events = await collectEvents(from: stream)

        // Verify Bash tool was invoked
        let toolStarts = events.compactMap { e -> String? in
            if case .toolUseStart(_, let name) = e { return name }
            return nil
        }
        #expect(toolStarts.contains("Bash"), "Expected Bash tool invocation, got: \(toolStarts)")

        // Verify tool result contains the echo output
        let toolResults = events.compactMap { e -> String? in
            if case .toolResult(_, let output, let isError) = e, !isError { return output }
            return nil
        }
        let hasEchoOutput = toolResults.contains { $0.contains("hello_integration_test") }
        #expect(hasEchoOutput, "Expected tool result to contain 'hello_integration_test'")

        // Verify completed
        let doneReasons = events.compactMap { e -> StopReason? in
            if case .done(let r) = e { return r }
            return nil
        }
        #expect(doneReasons.contains(.completed))
    }

    // MARK: 5. Permission blocking

    @Test("Permission blocking prevents tool execution gracefully")
    func permissionBlocking() async throws {
        let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-loop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let blockingCallback: PermissionCallback = { @Sendable _, _ in
            .block(reason: "All tools blocked for testing")
        }

        let transport = makeTransport(apiKey: apiKey, permissionCallback: blockingCallback)
        let stream = await transport.start(
            prompt: "Run 'echo test' in bash. Use the Bash tool.",
            systemPrompt: "You have a Bash tool. Use it when asked to run commands.",
            workingDirectory: tmpDir
        )
        let events = await collectEvents(from: stream)

        // Verify a tool result with permission denied was emitted
        let toolResults = events.compactMap { e -> (String, Bool)? in
            if case .toolResult(_, let output, let isError) = e {
                return (output, isError)
            }
            return nil
        }
        let hasPermissionDenied = toolResults.contains { $0.0.contains("Permission denied") && $0.1 }
        #expect(hasPermissionDenied, "Expected a permission denied tool result")

        // The loop should still complete (not crash)
        let doneReasons = events.compactMap { e -> StopReason? in
            if case .done(let r) = e { return r }
            return nil
        }
        #expect(!doneReasons.isEmpty, "Expected the loop to complete gracefully")
    }

    // MARK: 6. Token usage reporting

    @Test("Usage events are emitted with non-zero inputTokens")
    func tokenUsageReporting() async throws {
        let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]!

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-loop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let transport = makeTransport(apiKey: apiKey)
        let stream = await transport.start(
            prompt: "Say hello.",
            systemPrompt: "Be brief.",
            workingDirectory: tmpDir
        )
        let events = await collectEvents(from: stream)

        // Verify usage events with non-zero input tokens
        let usageEvents = events.compactMap { e -> (Int, Int)? in
            if case .usage(let input, let output, _, _) = e {
                return (input, output)
            }
            return nil
        }
        #expect(!usageEvents.isEmpty, "Expected at least one usage event")

        let hasNonZeroInput = usageEvents.contains { $0.0 > 0 }
        #expect(hasNonZeroInput, "Expected at least one usage event with non-zero inputTokens")
    }
}