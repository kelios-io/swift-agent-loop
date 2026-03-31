import Foundation

/// Generates synthetic SSE byte data for parse throughput benchmarks.
enum MockSSEData {

    /// Generate N SSE events as raw UTF-8 bytes, mimicking a realistic API response stream.
    static func generateEvents(count: Int) -> Data {
        var data = Data()

        // message_start
        let messageStart = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_bench","type":"message","role":"assistant","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":0}}}

        """
        data.append(Data(messageStart.utf8))

        // content_block_start
        let blockStart = """
        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        """
        data.append(Data(blockStart.utf8))

        // Generate N text_delta events
        for i in 0..<count {
            let delta = """
            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"word\(i) "}}

            """
            data.append(Data(delta.utf8))
        }

        // content_block_stop
        let blockStop = """
        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        """
        data.append(Data(blockStop.utf8))

        // message_delta + message_stop
        let ending = """
        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":50}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        data.append(Data(ending.utf8))

        return data
    }
}
