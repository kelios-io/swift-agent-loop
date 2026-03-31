import Testing
@testable import SwiftAgentLoop

// MARK: - Mock Byte Stream

/// Delivers pre-configured byte chunks as an async sequence.
struct MockByteStream: AsyncSequence, Sendable {
    typealias Element = UInt8
    let chunks: [[UInt8]]

    struct AsyncIterator: AsyncIteratorProtocol {
        var chunks: [[UInt8]]
        var chunkIndex = 0
        var byteIndex = 0

        mutating func next() async -> UInt8? {
            while chunkIndex < chunks.count {
                if byteIndex < chunks[chunkIndex].count {
                    let byte = chunks[chunkIndex][byteIndex]
                    byteIndex += 1
                    return byte
                }
                chunkIndex += 1
                byteIndex = 0
            }
            return nil
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: chunks)
    }
}

// MARK: - Helpers

/// Convert a string to a single chunk of bytes.
private func bytesChunk(_ string: String) -> [UInt8] {
    Array(string.utf8)
}

/// Collect all SSEEvents from a parser into an array.
private func collectEvents(from chunks: [[UInt8]]) async -> [SSEEvent] {
    let stream = MockByteStream(chunks: chunks)
    let parser = SSEParser(source: stream)
    var events: [SSEEvent] = []
    for await event in parser.events() {
        events.append(event)
    }
    return events
}

// MARK: - Canonical JSON payloads
// Note: JSON payloads use snake_case keys to match the Anthropic API format.
// The Codable types define explicit CodingKeys mapping snake_case to camelCase.

private let messageStartJSON = """
{"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":0}}}
"""

private let contentBlockDeltaTextJSON = """
{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
"""

private let contentBlockDeltaToolJSON = """
{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"key\\""}}
"""

private let messageStopJSON = """
{"type":"message_stop"}
"""

private let errorJSON = """
{"type":"error","message":"overloaded"}
"""

// MARK: - Tests

@Suite("SSE Parser")
struct SSEParserTests {

    // 1. Normal single event — a complete message_start event
    @Test("Parses a complete message_start event")
    func normalSingleEvent() async {
        let raw = "event: message_start\ndata: \(messageStartJSON)\n\n"
        let events = await collectEvents(from: [bytesChunk(raw)])

        #expect(events.count == 1)
        guard case .messageStart(let e) = events.first else {
            Issue.record("Expected messageStart, got \(String(describing: events.first))")
            return
        }
        #expect(e.message.id == "msg_123")
        #expect(e.message.model == "claude-sonnet-4-20250514")
        #expect(e.message.usage.inputTokens == 10)
    }

    // 2. Multiple events in one chunk
    @Test("Parses two events delivered in a single chunk")
    func multipleEventsOneChunk() async {
        let raw = "event: message_stop\ndata: \(messageStopJSON)\n\nevent: ping\ndata: {}\n\n"
        let events = await collectEvents(from: [bytesChunk(raw)])

        #expect(events.count == 2)
        guard case .messageStop = events[0] else {
            Issue.record("Expected messageStop at index 0")
            return
        }
        guard case .ping = events[1] else {
            Issue.record("Expected ping at index 1")
            return
        }
    }

    // 3. Event split across chunks
    @Test("Parses an event split across two chunks")
    func eventSplitAcrossChunks() async {
        let full = "event: message_start\ndata: \(messageStartJSON)\n\n"
        let mid = full.index(full.startIndex, offsetBy: full.count / 2)
        let chunk1 = Array(full[full.startIndex..<mid].utf8)
        let chunk2 = Array(full[mid...].utf8)

        let events = await collectEvents(from: [chunk1, chunk2])

        #expect(events.count == 1)
        guard case .messageStart(let e) = events.first else {
            Issue.record("Expected messageStart")
            return
        }
        #expect(e.message.id == "msg_123")
    }

    // 4. Split mid-field name — chunk boundary in the middle of "event:"
    @Test("Handles chunk boundary in the middle of a field name")
    func splitMidFieldName() async {
        let chunk1 = bytesChunk("eve")
        let chunk2 = bytesChunk("nt: message_stop\ndata: \(messageStopJSON)\n\n")

        let events = await collectEvents(from: [chunk1, chunk2])

        #expect(events.count == 1)
        guard case .messageStop = events.first else {
            Issue.record("Expected messageStop")
            return
        }
    }

    // 5. Split mid-UTF8 — a multi-byte UTF-8 character split across chunks
    @Test("Handles a multi-byte UTF-8 character split across chunks")
    func splitMidUTF8() async {
        // 🎵 is F0 9F 8E B5 in UTF-8. We embed it in a text_delta JSON payload
        // and split the byte sequence across two chunks.
        let jsonPrefix = Array(##"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""##.utf8)
        let jsonSuffix = Array(##""}}"##.utf8)
        let emoji: [UInt8] = [0xF0, 0x9F, 0x8E, 0xB5]

        let eventHeader = bytesChunk("event: content_block_delta\ndata: ")
        // Split emoji: first 2 bytes in chunk1, last 2 in chunk2
        let chunk1 = eventHeader + jsonPrefix + Array(emoji[0..<2])
        let chunk2 = Array(emoji[2..<4]) + jsonSuffix + bytesChunk("\n\n")

        let events = await collectEvents(from: [chunk1, chunk2])

        #expect(events.count == 1)
        guard case .contentBlockDelta(let e) = events.first else {
            Issue.record("Expected contentBlockDelta, got \(String(describing: events.first))")
            return
        }
        if case .textDelta(let text) = e.delta {
            #expect(text == "\u{1F3B5}")
        } else {
            Issue.record("Expected textDelta")
        }
    }

    // 6. Empty data field — "data:\n\n" with no value
    @Test("Handles empty data field")
    func emptyDataField() async {
        let raw = "event: ping\ndata:\n\n"
        let events = await collectEvents(from: [bytesChunk(raw)])

        #expect(events.count == 1)
        guard case .ping = events.first else {
            Issue.record("Expected ping, got \(String(describing: events.first))")
            return
        }
    }

    // 7. Multi-line data — consecutive data: fields joined with \n
    @Test("Joins consecutive data fields with newline")
    func multiLineData() async {
        // Two data: lines that form valid JSON when joined with \n.
        // JSON allows newlines as whitespace between tokens.
        let raw = "event: error\ndata: {\"type\":\"error\",\ndata: \"message\":\"oops\"}\n\n"
        let events = await collectEvents(from: [bytesChunk(raw)])

        #expect(events.count == 1)
        guard case .error(let apiErr) = events.first else {
            Issue.record("Expected error event, got \(String(describing: events.first))")
            return
        }
        #expect(apiErr.message == "oops")
    }

    // 8. Comment lines — lines starting with : should be skipped
    @Test("Skips comment lines starting with colon")
    func commentLines() async {
        let raw = ": this is a comment\nevent: ping\ndata: {}\n\n"
        let events = await collectEvents(from: [bytesChunk(raw)])

        #expect(events.count == 1)
        guard case .ping = events.first else {
            Issue.record("Expected ping")
            return
        }
    }

    // 9. CR/LF line endings
    @Test("Handles CR LF line endings")
    func crLfLineEndings() async {
        let raw = "event: message_stop\r\ndata: \(messageStopJSON)\r\n\r\n"
        let events = await collectEvents(from: [bytesChunk(raw)])

        #expect(events.count == 1)
        guard case .messageStop = events.first else {
            Issue.record("Expected messageStop")
            return
        }
    }

    // 10. Content block delta (text)
    @Test("Parses content_block_delta with text_delta")
    func contentBlockDeltaText() async {
        let raw = "event: content_block_delta\ndata: \(contentBlockDeltaTextJSON)\n\n"
        let events = await collectEvents(from: [bytesChunk(raw)])

        #expect(events.count == 1)
        guard case .contentBlockDelta(let e) = events.first else {
            Issue.record("Expected contentBlockDelta")
            return
        }
        #expect(e.index == 0)
        if case .textDelta(let text) = e.delta {
            #expect(text == "Hello")
        } else {
            Issue.record("Expected textDelta")
        }
    }

    // 11. Content block delta (tool input)
    @Test("Parses content_block_delta with input_json_delta")
    func contentBlockDeltaToolInput() async {
        let raw = "event: content_block_delta\ndata: \(contentBlockDeltaToolJSON)\n\n"
        let events = await collectEvents(from: [bytesChunk(raw)])

        #expect(events.count == 1)
        guard case .contentBlockDelta(let e) = events.first else {
            Issue.record("Expected contentBlockDelta")
            return
        }
        #expect(e.index == 1)
        if case .inputJSONDelta(let json) = e.delta {
            #expect(json == "{\"key\"")
        } else {
            Issue.record("Expected inputJSONDelta")
        }
    }

    // 12. Message stop
    @Test("Parses message_stop event")
    func messageStop() async {
        let raw = "event: message_stop\ndata: \(messageStopJSON)\n\n"
        let events = await collectEvents(from: [bytesChunk(raw)])

        #expect(events.count == 1)
        guard case .messageStop = events.first else {
            Issue.record("Expected messageStop")
            return
        }
    }

    // 13. Ping event
    @Test("Parses ping event with empty data")
    func pingEvent() async {
        let raw = "event: ping\ndata: {}\n\n"
        let events = await collectEvents(from: [bytesChunk(raw)])

        #expect(events.count == 1)
        guard case .ping = events.first else {
            Issue.record("Expected ping")
            return
        }
    }

    // 14. No space after colon
    @Test("Parses fields without space after colon")
    func noSpaceAfterColon() async {
        let raw = "event:message_stop\ndata:\(messageStopJSON)\n\n"
        let events = await collectEvents(from: [bytesChunk(raw)])

        #expect(events.count == 1)
        guard case .messageStop = events.first else {
            Issue.record("Expected messageStop")
            return
        }
    }

    // 15. Empty stream
    @Test("Empty stream produces no events")
    func emptyStream() async {
        let events = await collectEvents(from: [])
        #expect(events.isEmpty)
    }
}