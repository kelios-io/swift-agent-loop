import Foundation

// MARK: - MCP Types

/// A tool advertised by an MCP server via `tools/list`.
public struct MCPToolInfo: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema for the tool's input, as advertised by the server.
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Result of a `tools/call`. Text content parts are concatenated; non-text
/// parts are summarized inline.
public struct MCPCallResult: Sendable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

public enum MCPError: Error, Sendable {
    case notStarted
    case processLaunchFailed(String)
    case connectionClosed
    case protocolError(String)
    case serverError(code: Int, message: String)
    case timedOut(method: String)
}

// MARK: - JSON-RPC envelope

/// One JSON-RPC 2.0 message on the MCP stdio transport (newline-delimited).
struct JSONRPCEnvelope: Codable {
    var jsonrpc = "2.0"
    var id: Int?
    var method: String?
    var params: JSONValue?
    var result: JSONValue?
    var error: JSONRPCErrorObject?
}

struct JSONRPCErrorObject: Codable {
    let code: Int
    let message: String
}

// MARK: - MCPClient

/// Minimal MCP client over the stdio transport: spawns the server process,
/// performs the `initialize` handshake, and exposes `tools/list` and
/// `tools/call`. Requests are correlated by id; unknown incoming messages are
/// ignored (notifications) or answered with method-not-found (requests), per
/// the MCP spec's forward-compatibility rules.
public actor MCPClient {
    public static let protocolVersion = "2025-06-18"

    private let executable: String
    private let arguments: [String]
    private let extraEnvironment: [String: String]

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var started = false

    /// Per-request timeout. Generous: MCP servers may do real I/O.
    public var requestTimeout: TimeInterval = 60

    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.extraEnvironment = environment
    }

    // MARK: Lifecycle

    /// Launch the server process and perform the initialize handshake.
    public func start(clientName: String = "swift-agent-loop", clientVersion: String = "0.1.0") async throws {
        guard !started else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(extraEnvironment) { _, new in new }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Leave stderr attached to the host process for server-side logs.

        do {
            try process.run()
        } catch {
            throw MCPError.processLaunchFailed("\(executable): \(error.localizedDescription)")
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.started = true

        let stdout = stdoutPipe.fileHandleForReading
        readTask = Task { [weak self] in
            for await line in Self.lines(from: stdout) {
                await self?.handleLine(line)
            }
            await self?.connectionClosed()
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.connectionClosed() }
        }

        _ = try await request(method: "initialize", params: .object([
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(clientName),
                "version": .string(clientVersion),
            ]),
        ]))
        try notify(method: "notifications/initialized", params: .object([:]))
    }

    /// Terminate the server process. Pending requests fail with `.connectionClosed`.
    public func shutdown() {
        process?.terminationHandler = nil
        process?.terminate()
        connectionClosed()
        started = false
    }

    // MARK: Tools

    /// Fetch the server's tool catalog (follows `nextCursor` pagination).
    public func listTools() async throws -> [MCPToolInfo] {
        var tools: [MCPToolInfo] = []
        var cursor: JSONValue?
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await request(method: "tools/list", params: .object(params))
            guard case .object(let object) = result,
                  case .array(let entries)? = object["tools"] else {
                throw MCPError.protocolError("tools/list: missing tools array")
            }
            for entry in entries {
                guard case .object(let tool) = entry,
                      case .string(let name)? = tool["name"] else { continue }
                var description = ""
                if case .string(let text)? = tool["description"] { description = text }
                tools.append(MCPToolInfo(
                    name: name,
                    description: description,
                    inputSchema: tool["inputSchema"] ?? .object(["type": .string("object")])
                ))
            }
            cursor = object["nextCursor"]
            if case .null = cursor { cursor = nil }
        } while cursor != nil
        return tools
    }

    /// Invoke a tool. Text content parts are concatenated with newlines.
    /// Arguments are `JSONValue` so the call crosses the actor boundary as a
    /// Sendable value — bridge loose dictionaries with `JSONValue(bridging:)`.
    public func callTool(_ name: String, arguments: JSONValue) async throws -> MCPCallResult {
        let result = try await request(method: "tools/call", params: .object([
            "name": .string(name),
            "arguments": arguments,
        ]))
        guard case .object(let object) = result else {
            throw MCPError.protocolError("tools/call: non-object result")
        }
        var isError = false
        if case .bool(let flag)? = object["isError"] { isError = flag }
        var parts: [String] = []
        if case .array(let content)? = object["content"] {
            for part in content {
                guard case .object(let block) = part else { continue }
                if case .string("text")? = block["type"], case .string(let text)? = block["text"] {
                    parts.append(text)
                } else if case .string(let kind)? = block["type"] {
                    parts.append("[unsupported content type: \(kind)]")
                }
            }
        }
        return MCPCallResult(text: parts.joined(separator: "\n"), isError: isError)
    }

    // MARK: JSON-RPC plumbing

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard started else { throw MCPError.notStarted }
        let id = nextID
        nextID += 1

        var envelope = JSONRPCEnvelope()
        envelope.id = id
        envelope.method = method
        envelope.params = params
        try write(envelope)

        let timeout = requestTimeout
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.timeOut(id: id, method: method)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
        }
    }

    private func notify(method: String, params: JSONValue) throws {
        var envelope = JSONRPCEnvelope()
        envelope.method = method
        envelope.params = params
        try write(envelope)
    }

    private func write(_ envelope: JSONRPCEnvelope) throws {
        guard let stdinHandle else { throw MCPError.notStarted }
        var data = try JSONEncoder().encode(envelope)
        data.append(0x0A) // newline-delimited transport
        try stdinHandle.write(contentsOf: data)
    }

    private func handleLine(_ line: String) {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(JSONRPCEnvelope.self, from: data) else {
            return // not a JSON-RPC message; ignore (server may log to stdout by mistake)
        }
        if let id = envelope.id, envelope.method == nil {
            // Response to one of our requests.
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = envelope.error {
                continuation.resume(throwing: MCPError.serverError(code: error.code, message: error.message))
            } else {
                continuation.resume(returning: envelope.result ?? .null)
            }
        } else if let id = envelope.id, let method = envelope.method {
            // Server-initiated request; we support none. Answer method-not-found
            // so the server can proceed (per JSON-RPC).
            var reply = JSONRPCEnvelope()
            reply.id = id
            reply.error = JSONRPCErrorObject(code: -32601, message: "Method not supported: \(method)")
            try? write(reply)
        }
        // else: server notification — ignored.
    }

    private func timeOut(id: Int, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: MCPError.timedOut(method: method))
    }

    /// Newline-delimited lines from a pipe, streamed via `readabilityHandler`
    /// on GCD. NEVER use `FileHandle.bytes` here: it performs a blocking
    /// `read(2)` on the Swift cooperative thread pool, which starves every
    /// other task in the host process while the server is quiet (observed as
    /// a full app hang).
    private static func lines(from handle: FileHandle) -> AsyncStream<String> {
        final class Buffer: @unchecked Sendable {
            // Only touched from FileHandle's serial handler queue.
            var data = Data()
        }
        return AsyncStream { continuation in
            let buffer = Buffer()
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { // EOF
                    handle.readabilityHandler = nil
                    if !buffer.data.isEmpty, let line = String(data: buffer.data, encoding: .utf8) {
                        continuation.yield(line)
                    }
                    continuation.finish()
                    return
                }
                buffer.data.append(chunk)
                while let newline = buffer.data.firstIndex(of: 0x0A) {
                    var lineData = buffer.data.subdata(in: buffer.data.startIndex..<newline)
                    buffer.data.removeSubrange(buffer.data.startIndex...newline)
                    if lineData.last == 0x0D { lineData.removeLast() }
                    if let line = String(data: lineData, encoding: .utf8) {
                        continuation.yield(line)
                    }
                }
            }
            continuation.onTermination = { _ in
                handle.readabilityHandler = nil
            }
        }
    }

    private func connectionClosed() {
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError.connectionClosed)
        }
        pending.removeAll()
    }
}

// MARK: - JSONValue bridging

extension JSONValue {
    /// Best-effort bridge from loosely-typed dictionaries (tool inputs).
    init(bridging value: Any) {
        switch value {
        case let string as String: self = .string(string)
        case let bool as Bool: self = .bool(bool)
        case let int as Int: self = .integer(int)
        case let double as Double: self = .number(double)
        case let array as [Any]: self = .array(array.map { JSONValue(bridging: $0) })
        case let dict as [String: Any]: self = .object(dict.mapValues { JSONValue(bridging: $0) })
        default: self = .null
        }
    }

    /// Inverse bridge, for handing schemas to API request builders.
    var anyValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .integer(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map(\.anyValue)
        case .object(let values): return values.mapValues(\.anyValue)
        }
    }
}
