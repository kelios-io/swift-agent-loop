// MARK: - MessageStreaming Protocol

import Foundation

/// Protocol for streaming message responses. Enables mocking in tests.
public protocol MessageStreaming: Sendable {
    func stream(request: MessagesRequest) async -> AsyncStream<SSEEvent>
}

// MARK: - Anthropic HTTP Client

/// HTTP client for the Anthropic Messages API with streaming SSE support.
public actor AnthropicClient: MessageStreaming {
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let requestTimeout: TimeInterval

    /// Maximum retry attempts for rate-limited requests.
    private let maxRetries = 3

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 300
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.requestTimeout = requestTimeout
    }

    /// Send a messages request and stream SSE events back.
    public func stream(request: MessagesRequest) -> AsyncStream<SSEEvent> {
        let urlRequest: URLRequest
        do {
            urlRequest = try buildRequest(for: request)
        } catch {
            return AsyncStream { continuation in
                continuation.yield(.error(APIError(type: "request_error", message: error.localizedDescription)))
                continuation.finish()
            }
        }

        let currentSession = session
        let retries = maxRetries

        return AsyncStream { continuation in
            let task = Task {
                await Self.executeStream(
                    urlRequest: urlRequest,
                    session: currentSession,
                    maxRetries: retries,
                    continuation: continuation
                )
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Request Building

    private func buildRequest(for messagesRequest: MessagesRequest) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("v1/messages")
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"

        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")

        // Force stream = true for the wire request
        let streamRequest = MessagesRequest(
            model: messagesRequest.model,
            maxTokens: messagesRequest.maxTokens,
            messages: messagesRequest.messages,
            system: messagesRequest.system,
            tools: messagesRequest.tools,
            stream: true,
            temperature: messagesRequest.temperature,
            topP: messagesRequest.topP
        )

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(streamRequest)

        return request
    }

    // MARK: - Stream Execution

    private static func executeStream(
        urlRequest: URLRequest,
        session: URLSession,
        maxRetries: Int,
        continuation: AsyncStream<SSEEvent>.Continuation,
        attempt: Int = 0
    ) async {
        guard !Task.isCancelled else {
            continuation.finish()
            return
        }

        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                continuation.yield(.error(APIError(type: "network_error", message: "Invalid response type")))
                continuation.finish()
                return
            }

            let statusCode = httpResponse.statusCode

            // Handle retryable status codes (rate limit + server errors)
            let isRetryable = statusCode == 429 || (statusCode >= 500 && statusCode <= 599)
            if isRetryable {
                if attempt < maxRetries {
                    let retryAfter = retryDelay(from: httpResponse, attempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                    await executeStream(
                        urlRequest: urlRequest,
                        session: session,
                        maxRetries: maxRetries,
                        continuation: continuation,
                        attempt: attempt + 1
                    )
                    return
                } else {
                    continuation.yield(.error(APIError(
                        type: "retry_error",
                        message: "HTTP \(statusCode) after \(maxRetries) retries"
                    )))
                    continuation.finish()
                    return
                }
            }

            // Handle other error status codes
            if statusCode < 200 || statusCode >= 300 {
                // Try to read the error body
                var bodyBytes: [UInt8] = []
                for try await byte in bytes.prefix(8192) {
                    bodyBytes.append(byte)
                }
                let bodyString = String(bytes: bodyBytes, encoding: .utf8) ?? "Unknown error"

                if let bodyData = bodyString.data(using: .utf8),
                   let apiError = try? JSONDecoder().decode(ErrorWrapper.self, from: bodyData) {
                    continuation.yield(.error(apiError.error))
                } else {
                    continuation.yield(.error(APIError(
                        type: "api_error",
                        message: "HTTP \(statusCode): \(bodyString)"
                    )))
                }
                continuation.finish()
                return
            }

            // Success — pipe bytes through SSE parser
            let parser = SSEParser(source: bytes)
            for await event in parser.events() {
                if Task.isCancelled { break }
                continuation.yield(event)
            }

            continuation.finish()

        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.yield(.error(APIError(type: "network_error", message: error.localizedDescription)))
            continuation.finish()
        }
    }

    /// Calculate retry delay from `retry-after` header or exponential backoff.
    private static func retryDelay(from response: HTTPURLResponse, attempt: Int) -> Double {
        if let retryAfterStr = response.value(forHTTPHeaderField: "retry-after"),
           let retryAfter = Double(retryAfterStr) {
            return retryAfter
        }
        // Exponential backoff with jitter: 1s, 2s, 4s × random(0.5–1.5)
        let base = pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0.5...1.5)
        return base * jitter
    }
}

// MARK: - Error Response Wrapper

/// Anthropic API wraps errors in `{ "error": { "type": "...", "message": "..." } }`.
private struct ErrorWrapper: Decodable {
    let error: APIError
}