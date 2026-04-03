// MARK: - MessageStreaming Protocol

import Foundation

/// Protocol for streaming message responses. Enables mocking in tests.
public protocol MessageStreaming: Sendable {
    func stream(request: MessagesRequest) async -> AsyncStream<SSEEvent>
}

// MARK: - Anthropic HTTP Client

/// HTTP client for the Anthropic Messages API with streaming SSE support.
public actor AnthropicClient: MessageStreaming {
    private let credential: AuthCredential
    private let baseURL: URL
    private let session: URLSession
    private let requestTimeout: TimeInterval

    /// Maximum retry attempts for rate-limited requests.
    private let maxRetries = 3

    public init(
        credential: AuthCredential,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 300
    ) {
        self.credential = credential
        self.baseURL = baseURL
        self.session = session
        self.requestTimeout = requestTimeout
    }

    /// Convenience initializer for API key authentication (backward compatible).
    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared,
        requestTimeout: TimeInterval = 300
    ) {
        self.init(credential: .apiKey(apiKey), baseURL: baseURL, session: session, requestTimeout: requestTimeout)
    }

    /// Send a messages request and stream SSE events back.
    public func stream(request: MessagesRequest) async -> AsyncStream<SSEEvent> {
        let urlRequest: URLRequest
        do {
            urlRequest = try await buildRequest(for: request)
        } catch {
            return AsyncStream { continuation in
                continuation.yield(.error(APIError(type: "request_error", message: error.localizedDescription)))
                continuation.finish()
            }
        }

        let cred = credential
        let currentSession = session
        let retries = maxRetries

        // Build 401 retry closure for OAuth
        let retryOn401: (@Sendable () async -> URLRequest?)?
        if case .oauth(let manager) = cred {
            let capturedRequest = urlRequest
            retryOn401 = {
                guard let token = try? await manager.forceRefresh() else { return nil }
                var req = capturedRequest
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return req
            }
        } else {
            retryOn401 = nil
        }

        return AsyncStream { continuation in
            let task = Task {
                await Self.executeStream(
                    urlRequest: urlRequest,
                    session: currentSession,
                    maxRetries: retries,
                    continuation: continuation,
                    retryOn401: retryOn401
                )
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Request Building

    private func buildRequest(for messagesRequest: MessagesRequest) async throws -> URLRequest {
        let url = baseURL.appendingPathComponent("v1/messages")
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"

        switch credential {
        case .apiKey(let key):
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .oauth(let manager):
            let token = try await manager.validAccessToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }

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
            topP: messagesRequest.topP,
            thinking: messagesRequest.thinking,
            contextManagement: messagesRequest.contextManagement
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
        attempt: Int = 0,
        retryOn401: (@Sendable () async -> URLRequest?)? = nil
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

            // Handle 401 with OAuth token refresh (retry once)
            if statusCode == 401, let retryOn401 {
                if let freshRequest = await retryOn401() {
                    await executeStream(
                        urlRequest: freshRequest,
                        session: session,
                        maxRetries: maxRetries,
                        continuation: continuation,
                        attempt: 0,
                        retryOn401: nil // only retry auth once
                    )
                    return
                }
            }

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
                        attempt: attempt + 1,
                        retryOn401: retryOn401
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
