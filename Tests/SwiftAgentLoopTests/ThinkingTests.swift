import Testing
import Foundation
@testable import SwiftAgentLoop

@Suite("Extended Thinking")
struct ThinkingTests {

    // MARK: - 1. ThinkingConfig encoding with budget

    @Test("ThinkingConfig encodes with budget_tokens")
    func thinkingConfigWithBudget() throws {
        let config = ThinkingConfig(budgetTokens: 10000)
        let data = try JSONEncoder().encode(config)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"type\":\"enabled\""))
        #expect(json.contains("\"budget_tokens\":10000"))
    }

    // MARK: - 2. ThinkingConfig encoding without budget (adaptive)

    @Test("ThinkingConfig encodes without budget_tokens for adaptive thinking")
    func thinkingConfigAdaptive() throws {
        let config = ThinkingConfig()
        let data = try JSONEncoder().encode(config)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"type\":\"enabled\""))
        #expect(!json.contains("budget_tokens"))
    }

    // MARK: - 3. MessagesRequest includes thinking when set

    @Test("MessagesRequest includes thinking field when configured")
    func messagesRequestWithThinking() throws {
        let request = MessagesRequest(
            model: "claude-sonnet-4-6",
            maxTokens: 4096,
            messages: [],
            thinking: ThinkingConfig(budgetTokens: 5000)
        )
        let data = try JSONEncoder().encode(request)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"thinking\""))
        #expect(json.contains("\"budget_tokens\":5000"))
    }

    // MARK: - 4. MessagesRequest omits thinking when nil

    @Test("MessagesRequest omits thinking field when nil")
    func messagesRequestWithoutThinking() throws {
        let request = MessagesRequest(
            model: "claude-sonnet-4-6",
            maxTokens: 4096,
            messages: []
        )
        let data = try JSONEncoder().encode(request)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("\"thinking\""))
    }

    // MARK: - 5. ThinkingBlock round-trips with signature

    @Test("ThinkingBlock preserves signature through encode/decode")
    func thinkingBlockSignatureRoundTrip() throws {
        let block = ThinkingBlock(thinking: "Let me think...", signature: "sig_abc123")
        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(ThinkingBlock.self, from: data)
        #expect(decoded.thinking == "Let me think...")
        #expect(decoded.signature == "sig_abc123")
        #expect(decoded.type == "thinking")
    }

    // MARK: - 6. ThinkingBlock works without signature

    @Test("ThinkingBlock works without signature")
    func thinkingBlockWithoutSignature() throws {
        let block = ThinkingBlock(thinking: "thinking text")
        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(ThinkingBlock.self, from: data)
        #expect(decoded.thinking == "thinking text")
        #expect(decoded.signature == nil)
    }
}
