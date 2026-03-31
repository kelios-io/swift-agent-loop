import Foundation

/// Manages conversation context window.
/// Currently a pass-through; server-side compaction will be added in E2.
public struct ContextManager: Sendable {
    public init() {}

    /// Returns messages unmodified. Compaction logic deferred to E2.
    public func compact(messages: [Message]) -> [Message] {
        messages
    }
}
