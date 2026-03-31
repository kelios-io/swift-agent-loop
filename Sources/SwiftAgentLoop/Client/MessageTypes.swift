// MARK: - Anthropic Messages API Types

import Foundation

/// Anthropic API version pinned for all requests.
public let anthropicAPIVersion = "2024-10-22"

// MARK: - Request Types

public struct MessagesRequest: Codable, Sendable {
    public let model: String
    public let maxTokens: Int
    public let messages: [Message]
    public let system: [SystemBlock]?
    public let tools: [ToolDefinition]?
    public let stream: Bool
    public let temperature: Double?
    public let topP: Double?
    public let thinking: ThinkingConfig?
    public let contextManagement: ContextManagementConfig?

    public init(
        model: String,
        maxTokens: Int,
        messages: [Message],
        system: [SystemBlock]? = nil,
        tools: [ToolDefinition]? = nil,
        stream: Bool = false,
        temperature: Double? = nil,
        topP: Double? = nil,
        thinking: ThinkingConfig? = nil,
        contextManagement: ContextManagementConfig? = nil
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.messages = messages
        self.system = system
        self.tools = tools
        self.stream = stream
        self.temperature = temperature
        self.topP = topP
        self.thinking = thinking
        self.contextManagement = contextManagement
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages
        case system
        case tools
        case stream
        case temperature
        case topP = "top_p"
        case thinking
        case contextManagement = "context_management"
    }
}

// MARK: - Thinking Configuration

/// Configuration for extended thinking in API requests.
/// Use `budgetTokens: nil` for adaptive thinking on Opus/Sonnet 4.6.
public struct ThinkingConfig: Codable, Sendable {
    public let type: String
    public let budgetTokens: Int?

    public init(type: String = "enabled", budgetTokens: Int? = nil) {
        self.type = type
        self.budgetTokens = budgetTokens
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }
}

// MARK: - Context Management Configuration

/// Configuration for server-side context compression.
public struct ContextManagementConfig: Codable, Sendable {
    public let edits: [CompactionEdit]

    public init(edits: [CompactionEdit] = [CompactionEdit()]) {
        self.edits = edits
    }
}

/// A single compaction edit directive.
public struct CompactionEdit: Codable, Sendable {
    public let type: String

    public init(type: String = "compact_20260112") {
        self.type = type
    }
}

public struct Message: Codable, Sendable {
    public let role: MessageRole
    public let content: MessageContent

    public init(role: MessageRole, content: MessageContent) {
        self.role = role
        self.content = content
    }
}

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

/// Encodes as a plain string for simple text, or an array of ContentBlock for rich content.
public enum MessageContent: Codable, Sendable {
    case text(String)
    case blocks([ContentBlock])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else {
            let blocks = try container.decode([ContentBlock].self)
            self = .blocks(blocks)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
            try container.encode(string)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }
}

public struct SystemBlock: Codable, Sendable {
    public let type: String
    public let text: String
    public let cacheControl: CacheControl?

    public init(type: String = "text", text: String, cacheControl: CacheControl? = nil) {
        self.type = type
        self.text = text
        self.cacheControl = cacheControl
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case cacheControl = "cache_control"
    }
}

public struct CacheControl: Codable, Sendable {
    public let type: String

    public init(type: String = "ephemeral") {
        self.type = type
    }
}

// MARK: - Content Blocks

/// Discriminated union over content block types, keyed on `type`.
public enum ContentBlock: Codable, Sendable {
    case text(TextBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case thinking(ThinkingBlock)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try TextBlock(from: decoder))
        case "tool_use":
            self = .toolUse(try ToolUseBlock(from: decoder))
        case "tool_result":
            self = .toolResult(try ToolResultBlock(from: decoder))
        case "thinking":
            self = .thinking(try ThinkingBlock(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown content block type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let block):
            try block.encode(to: encoder)
        case .toolUse(let block):
            try block.encode(to: encoder)
        case .toolResult(let block):
            try block.encode(to: encoder)
        case .thinking(let block):
            try block.encode(to: encoder)
        }
    }
}

public struct TextBlock: Codable, Sendable {
    public let type: String
    public let text: String

    public init(text: String) {
        self.type = "text"
        self.text = text
    }
}

public struct ToolUseBlock: Codable, Sendable {
    public let type: String
    public let id: String
    public let name: String
    public let input: [String: JSONValue]

    public init(id: String, name: String, input: [String: JSONValue]) {
        self.type = "tool_use"
        self.id = id
        self.name = name
        self.input = input
    }
}

public struct ToolResultBlock: Codable, Sendable {
    public let type: String
    public let toolUseId: String
    public let content: String
    public let isError: Bool?

    public init(toolUseId: String, content: String, isError: Bool? = nil) {
        self.type = "tool_result"
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }
}

public struct ThinkingBlock: Codable, Sendable {
    public let type: String
    public let thinking: String
    /// Cryptographic signature from the API. Must be preserved byte-identical
    /// when round-tripping thinking blocks through tool-use loops.
    public let signature: String?

    public init(thinking: String, signature: String? = nil) {
        self.type = "thinking"
        self.thinking = thinking
        self.signature = signature
    }
}

// MARK: - Tool Definition

public struct ToolDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }
}

// MARK: - JSONValue

/// A type-safe representation of arbitrary JSON values.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let int = try? container.decode(Int.self) {
            self = .integer(int)
            return
        }
        if let double = try? container.decode(Double.self) {
            self = .number(double)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
            return
        }
        if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unable to decode JSONValue"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

// MARK: - SSE Event Types

public enum SSEEvent: Sendable {
    case messageStart(MessageStartEvent)
    case contentBlockStart(ContentBlockStartEvent)
    case contentBlockDelta(ContentBlockDeltaEvent)
    case contentBlockStop(ContentBlockStopEvent)
    case messageDelta(MessageDeltaEvent)
    case messageStop
    case ping
    case error(APIError)
}

public struct MessageStartEvent: Codable, Sendable {
    public let type: String
    public let message: MessageStartMessage
}

public struct MessageStartMessage: Codable, Sendable {
    public let id: String
    public let type: String
    public let role: String
    public let model: String
    public let usage: Usage
}

public struct ContentBlockStartEvent: Codable, Sendable {
    public let type: String
    public let index: Int
    public let contentBlock: ContentBlockInfo

    private enum CodingKeys: String, CodingKey {
        case type
        case index
        case contentBlock = "content_block"
    }
}

public struct ContentBlockInfo: Codable, Sendable {
    public let type: String
    public let id: String?
    public let name: String?
    public let text: String?
    public let thinking: String?
    public let signature: String?

    public init(type: String, id: String? = nil, name: String? = nil, text: String? = nil, thinking: String? = nil, signature: String? = nil) {
        self.type = type
        self.id = id
        self.name = name
        self.text = text
        self.thinking = thinking
        self.signature = signature
    }
}

public struct ContentBlockDeltaEvent: Codable, Sendable {
    public let type: String
    public let index: Int
    public let delta: DeltaContent

    private enum CodingKeys: String, CodingKey {
        case type
        case index
        case delta
    }
}

/// Delta content discriminated by `type` field.
public enum DeltaContent: Codable, Sendable {
    case textDelta(text: String)
    case inputJSONDelta(partialJSON: String)
    case thinkingDelta(thinking: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case partialJson = "partial_json"
        case thinking
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text_delta":
            let text = try container.decode(String.self, forKey: .text)
            self = .textDelta(text: text)
        case "input_json_delta":
            let json = try container.decode(String.self, forKey: .partialJson)
            self = .inputJSONDelta(partialJSON: json)
        case "thinking_delta":
            let thinking = try container.decode(String.self, forKey: .thinking)
            self = .thinkingDelta(thinking: thinking)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown delta type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .textDelta(let text):
            try container.encode("text_delta", forKey: .type)
            try container.encode(text, forKey: .text)
        case .inputJSONDelta(let json):
            try container.encode("input_json_delta", forKey: .type)
            try container.encode(json, forKey: .partialJson)
        case .thinkingDelta(let thinking):
            try container.encode("thinking_delta", forKey: .type)
            try container.encode(thinking, forKey: .thinking)
        }
    }
}

public struct ContentBlockStopEvent: Codable, Sendable {
    public let type: String
    public let index: Int
    /// Cryptographic signature for thinking blocks, delivered on stop.
    public let signature: String?

    public init(type: String, index: Int, signature: String? = nil) {
        self.type = type
        self.index = index
        self.signature = signature
    }
}

public struct MessageDeltaEvent: Codable, Sendable {
    public let type: String
    public let delta: MessageDelta
    public let usage: DeltaUsage
}

public struct MessageDelta: Codable, Sendable {
    public let stopReason: String?

    private enum CodingKeys: String, CodingKey {
        case stopReason = "stop_reason"
    }
}

public struct DeltaUsage: Codable, Sendable {
    public let outputTokens: Int

    private enum CodingKeys: String, CodingKey {
        case outputTokens = "output_tokens"
    }
}

public struct Usage: Codable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadInputTokens: Int?
    public let cacheCreationInputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}

public struct APIError: Codable, Sendable, Error {
    public let type: String
    public let message: String

    public init(type: String, message: String) {
        self.type = type
        self.message = message
    }
}