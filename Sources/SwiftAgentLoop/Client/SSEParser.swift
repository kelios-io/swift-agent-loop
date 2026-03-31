// MARK: - SSE Parser State Machine

import Foundation

/// Parses Server-Sent Events from a byte stream into typed SSEEvent values.
/// Uses an explicit state machine to handle arbitrary chunk boundaries correctly.
///
/// URLSession's AsyncBytes delivers data in arbitrary chunks — a single SSE event
/// can span multiple chunks, or one chunk can contain multiple events. This parser
/// processes bytes one at a time through a state machine, accumulating into byte
/// buffers and only converting to String at field boundaries (so multi-byte UTF-8
/// sequences split across chunks are handled correctly).
public struct SSEParser<Source: AsyncSequence & Sendable> where Source.Element == UInt8 {
    let source: Source

    public init(source: Source) {
        self.source = source
    }

    public func events() -> AsyncStream<SSEEvent> {
        let src = source
        return AsyncStream { continuation in
            Task {
                var state: ParseState = .idle
                var fieldNameBytes: [UInt8] = []
                var fieldValueBytes: [UInt8] = []
                var currentEventType = ""
                var dataLines: [String] = []
                var sawCR = false

                let decoder = JSONDecoder()
                // Note: Do NOT use .convertFromSnakeCase here — the Codable types
                // already define explicit CodingKeys with snake_case raw values,
                // and .convertFromSnakeCase conflicts with explicit CodingKeys.

                func dispatchEvent() {
                    let eventType = currentEventType
                    let data = dataLines.joined(separator: "\n")
                    // Reset accumulators
                    currentEventType = ""
                    dataLines = []

                    guard !eventType.isEmpty else { return }

                    if let sseEvent = Self.parseEvent(
                        eventType: eventType,
                        data: data,
                        decoder: decoder
                    ) {
                        continuation.yield(sseEvent)
                    }
                }

                func commitField() {
                    let name = String(bytes: fieldNameBytes, encoding: .utf8) ?? ""
                    // Strip optional leading space after colon
                    var value = fieldValueBytes
                    if let first = value.first, first == 0x20 /* space */ {
                        value.removeFirst()
                    }
                    let valueStr = String(bytes: value, encoding: .utf8) ?? ""

                    switch name {
                    case "event":
                        currentEventType = valueStr
                    case "data":
                        dataLines.append(valueStr)
                    default:
                        // Ignore id:, retry:, and unknown fields
                        break
                    }

                    fieldNameBytes = []
                    fieldValueBytes = []
                }

                do {
                    for try await byte in src {
                        // Handle \r\n sequences: if we saw \r and now see \n, consume the \n
                        if sawCR {
                            sawCR = false
                            if byte == 0x0A /* \n */ {
                                // Already processed the \r as a line ending; skip this \n
                                continue
                            }
                        }

                        // Normalize \r to \n for processing
                        let b: UInt8 = (byte == 0x0D) ? 0x0A : byte
                        if byte == 0x0D {
                            sawCR = true
                        }

                        switch state {
                        case .idle:
                            if b == 0x0A {
                                // Blank line while idle: dispatch if we have accumulated data
                                dispatchEvent()
                            } else if b == 0x3A /* : */ {
                                // Comment line — skip until end of line
                                state = .comment
                            } else {
                                // Start of a field name
                                fieldNameBytes = [b]
                                state = .fieldName
                            }

                        case .fieldName:
                            if b == 0x3A /* : */ {
                                state = .fieldValue
                            } else if b == 0x0A {
                                // Field with no colon — treat entire line as field name with empty value
                                // Per SSE spec, this is valid but we just ignore it
                                fieldNameBytes = []
                                state = .sawNewline
                            } else {
                                fieldNameBytes.append(b)
                            }

                        case .fieldValue:
                            if b == 0x0A {
                                commitField()
                                state = .sawNewline
                            } else {
                                fieldValueBytes.append(b)
                            }

                        case .sawNewline:
                            if b == 0x0A {
                                // Two consecutive newlines: dispatch event
                                dispatchEvent()
                                state = .idle
                            } else if b == 0x3A /* : */ {
                                // Comment line
                                state = .comment
                            } else {
                                // Start of next field
                                fieldNameBytes = [b]
                                state = .fieldName
                            }

                        case .comment:
                            if b == 0x0A {
                                // End of comment line
                                state = .sawNewline
                            }
                            // Otherwise skip comment bytes
                        }
                    }

                    // End of stream — dispatch any remaining event
                    if !currentEventType.isEmpty || !dataLines.isEmpty {
                        if state == .fieldValue {
                            commitField()
                        }
                        dispatchEvent()
                    }

                    continuation.finish()
                } catch {
                    // Dispatch any remaining event before finishing on error
                    if !currentEventType.isEmpty || !dataLines.isEmpty {
                        if state == .fieldValue {
                            commitField()
                        }
                        dispatchEvent()
                    }
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Event Parsing

    private static func parseEvent(
        eventType: String,
        data: String,
        decoder: JSONDecoder
    ) -> SSEEvent? {
        switch eventType {
        case "message_start":
            guard let jsonData = data.data(using: .utf8),
                  let event = try? decoder.decode(MessageStartEvent.self, from: jsonData) else {
                return .error(APIError(type: "parse_error", message: "Failed to decode \(eventType) event"))
            }
            return .messageStart(event)

        case "content_block_start":
            guard let jsonData = data.data(using: .utf8),
                  let event = try? decoder.decode(ContentBlockStartEvent.self, from: jsonData) else {
                return .error(APIError(type: "parse_error", message: "Failed to decode \(eventType) event"))
            }
            return .contentBlockStart(event)

        case "content_block_delta":
            guard let jsonData = data.data(using: .utf8),
                  let event = try? decoder.decode(ContentBlockDeltaEvent.self, from: jsonData) else {
                return .error(APIError(type: "parse_error", message: "Failed to decode \(eventType) event"))
            }
            return .contentBlockDelta(event)

        case "content_block_stop":
            guard let jsonData = data.data(using: .utf8),
                  let event = try? decoder.decode(ContentBlockStopEvent.self, from: jsonData) else {
                return .error(APIError(type: "parse_error", message: "Failed to decode \(eventType) event"))
            }
            return .contentBlockStop(event)

        case "message_delta":
            guard let jsonData = data.data(using: .utf8),
                  let event = try? decoder.decode(MessageDeltaEvent.self, from: jsonData) else {
                return .error(APIError(type: "parse_error", message: "Failed to decode \(eventType) event"))
            }
            return .messageDelta(event)

        case "message_stop":
            return .messageStop

        case "ping":
            return .ping

        case "error":
            guard let jsonData = data.data(using: .utf8),
                  let event = try? decoder.decode(APIError.self, from: jsonData) else {
                return .error(APIError(type: "parse_error", message: "Failed to decode \(eventType) event"))
            }
            return .error(event)

        default:
            // Unknown event types are expected for forward compatibility
            return nil
        }
    }
}

// MARK: - Parse State

private enum ParseState {
    /// No bytes accumulated yet, expecting field start or blank line.
    case idle
    /// Accumulating field name bytes until ':' or newline.
    case fieldName
    /// Accumulating field value bytes until newline.
    case fieldValue
    /// Saw a newline; next newline means dispatch, otherwise start new field.
    case sawNewline
    /// Inside a comment line (starts with ':'); skip until newline.
    case comment
}