import Foundation

/// Manages conversation context window.
///
/// E2: Server-side compaction via the `context_management` API parameter.
/// E3: Client-side autocompact with token estimation and threshold triggers.
public struct ContextManager: Sendable {
    public let contextCompressionEnabled: Bool

    public init(contextCompressionEnabled: Bool = false) {
        self.contextCompressionEnabled = contextCompressionEnabled
    }

    /// Returns the context management config for API requests, if compression is enabled.
    public func contextManagementConfig() -> ContextManagementConfig? {
        guard contextCompressionEnabled else { return nil }
        return ContextManagementConfig()
    }

    /// Returns messages, potentially compacted. Client-side compaction deferred to E3.
    public func compact(messages: [Message]) -> [Message] {
        messages
    }
}
