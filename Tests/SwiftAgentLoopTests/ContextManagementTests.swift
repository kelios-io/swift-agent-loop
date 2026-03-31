import Testing
import Foundation
@testable import SwiftAgentLoop

@Suite("Context Management")
struct ContextManagementTests {

    // MARK: - 1. ContextManagementConfig encoding

    @Test("ContextManagementConfig encodes with default compact edit")
    func contextManagementConfigEncoding() throws {
        let config = ContextManagementConfig()
        let data = try JSONEncoder().encode(config)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"edits\""))
        #expect(json.contains("\"type\":\"compact_20260112\""))
    }

    // MARK: - 2. MessagesRequest includes context_management

    @Test("MessagesRequest includes context_management when configured")
    func messagesRequestWithContextManagement() throws {
        let request = MessagesRequest(
            model: "claude-sonnet-4-6",
            maxTokens: 4096,
            messages: [],
            contextManagement: ContextManagementConfig()
        )
        let data = try JSONEncoder().encode(request)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"context_management\""))
        #expect(json.contains("compact_20260112"))
    }

    // MARK: - 3. MessagesRequest omits context_management when nil

    @Test("MessagesRequest omits context_management when nil")
    func messagesRequestWithoutContextManagement() throws {
        let request = MessagesRequest(
            model: "claude-sonnet-4-6",
            maxTokens: 4096,
            messages: []
        )
        let data = try JSONEncoder().encode(request)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("context_management"))
    }

    // MARK: - 4. ContextManager provides config when enabled

    @Test("ContextManager returns config when compression enabled")
    func contextManagerEnabled() {
        let manager = ContextManager(contextCompressionEnabled: true)
        let config = manager.contextManagementConfig()
        #expect(config != nil)
        #expect(config?.edits.count == 1)
    }

    // MARK: - 5. ContextManager returns nil when disabled

    @Test("ContextManager returns nil when compression disabled")
    func contextManagerDisabled() {
        let manager = ContextManager(contextCompressionEnabled: false)
        #expect(manager.contextManagementConfig() == nil)
    }
}
