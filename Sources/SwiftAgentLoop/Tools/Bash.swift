@preconcurrency import Dispatch
import Foundation

// MARK: - BashTool

/// Executes bash commands via Foundation Process with timeout and output truncation.
///
/// Uses GCD `availableData` loops for reliable pipe reading (never swift-subprocess).
/// Output is capped at ~1MB to prevent memory blowup on chatty commands.
public struct BashTool: AgentTool {
    public let name = "Bash"
    public let description = "Executes a given bash command and returns its output."
    public let isReadOnly = false
    public var timeout: TimeInterval { 600 }

    /// Default timeout: 120 seconds.
    private static let defaultTimeoutMs = 120_000
    /// Maximum allowed timeout: 600 seconds.
    private static let maxTimeoutMs = 600_000
    /// Maximum output size: ~1MB.
    private static let maxOutputBytes = 1_048_576

    public let inputSchema = InputSchema([
        "type": "object",
        "required": ["command"],
        "properties": [
            "command": [
                "type": "string",
                "description": "The command to execute",
            ],
            "timeout": [
                "type": "integer",
                "description": "Optional timeout in milliseconds (max 600000)",
            ],
            "description": [
                "type": "string",
                "description": "Clear description of what this command does",
            ],
            "run_in_background": [
                "type": "boolean",
                "description": "Set to true to run this command in the background",
            ],
        ] as [String: Any],
    ])

    public init() {}

    // MARK: - Validation

    public func validate(input: [String: Any], context: ToolContext) throws {
        guard let command = input["command"] as? String else {
            throw ToolError.missingParameter("command")
        }
        guard !command.isEmpty else {
            throw ToolError.invalidParameter(name: "command", message: "command must not be empty")
        }
    }

    // MARK: - Execution

    public func execute(input: [String: Any], context: ToolContext) async throws -> ToolResult {
        guard let command = input["command"] as? String, !command.isEmpty else {
            return .error("command is required and must be a non-empty string")
        }

        let timeoutMs: Int
        if let t = input["timeout"] as? Int {
            timeoutMs = min(t, Self.maxTimeoutMs)
        } else {
            timeoutMs = Self.defaultTimeoutMs
        }

        return await runProcess(
            command: command,
            workingDirectory: context.workingDirectory,
            timeoutMs: timeoutMs
        )
    }

    // MARK: - Process Execution

    /// Runs a bash command via Foundation Process with GCD pipe readers and timeout.
    private func runProcess(
        command: String,
        workingDirectory: URL,
        timeoutMs: Int
    ) async -> ToolResult {
        await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", command]
            proc.currentDirectoryURL = workingDirectory
            proc.environment = ProcessInfo.processInfo.environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            let stdoutBuffer = LockedBuffer(maxSize: Self.maxOutputBytes)
            let stderrBuffer = LockedBuffer(maxSize: Self.maxOutputBytes)

            // Track whether continuation has been resumed to prevent double-resume
            let resumed = AtomicFlag()

            // Coordinate pipe readers finishing before building result
            let group = DispatchGroup()

            // Read stdout on background thread
            group.enter()
            let stdoutHandle = stdoutPipe.fileHandleForReading
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let data = stdoutHandle.availableData
                    if data.isEmpty { break } // EOF
                    stdoutBuffer.append(data)
                }
                stdoutHandle.closeFile()
                group.leave()
            }

            // Read stderr on background thread
            group.enter()
            let stderrHandle = stderrPipe.fileHandleForReading
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let data = stderrHandle.availableData
                    if data.isEmpty { break } // EOF
                    stderrBuffer.append(data)
                }
                stderrHandle.closeFile()
                group.leave()
            }

            // Timeout: SIGTERM first, SIGINT after 3s fallback
            let timeoutSeconds = Double(timeoutMs) / 1000.0
            let timeoutWork = DispatchWorkItem { [proc] in
                guard proc.isRunning else { return }
                proc.terminate() // SIGTERM

                // SIGINT fallback after 3s
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if proc.isRunning {
                        proc.interrupt() // SIGINT
                    }
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeoutSeconds,
                execute: timeoutWork
            )

            // Termination handler — wait for pipe readers, then resume continuation
            proc.terminationHandler = { finished in
                let wasTimeout = timeoutWork.isCancelled == false
                timeoutWork.cancel()

                // Wait for readers to drain remaining pipe data
                group.wait()

                guard resumed.setIfFirst() else { return }

                let exitCode = finished.terminationStatus
                let stdout = stdoutBuffer.string
                let stderr = stderrBuffer.string
                let truncated = stdoutBuffer.isTruncated || stderrBuffer.isTruncated

                let result = Self.buildResult(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: exitCode,
                    timedOut: exitCode == 15 && wasTimeout,
                    timeoutMs: timeoutMs,
                    truncated: truncated
                )
                continuation.resume(returning: result)
            }

            // Launch
            do {
                try proc.run()
            } catch {
                timeoutWork.cancel()
                guard resumed.setIfFirst() else { return }
                continuation.resume(returning: .error("Failed to start process: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Result Building

    private static func buildResult(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        timedOut: Bool,
        timeoutMs: Int,
        truncated: Bool
    ) -> ToolResult {
        if timedOut {
            let seconds = timeoutMs / 1000
            var content = "Command timed out after \(seconds)s"
            if !stdout.isEmpty { content += "\n\nstdout:\n\(stdout)" }
            if !stderr.isEmpty { content += "\n\nstderr:\n\(stderr)" }
            if truncated { content += "\n\n...[output truncated at 1MB]" }
            return .error(content)
        }

        if exitCode != 0 {
            var content = "Exit code: \(exitCode)"
            if !stdout.isEmpty { content += "\n\nstdout:\n\(stdout)" }
            if !stderr.isEmpty { content += "\n\nstderr:\n\(stderr)" }
            if truncated { content += "\n\n...[output truncated at 1MB]" }
            return ToolResult(content: content, isError: true)
        }

        // Success
        var content = stdout
        if !stderr.isEmpty {
            content += "\n\nstderr:\n\(stderr)"
        }
        if truncated {
            content += "\n\n...[output truncated at 1MB]"
        }
        return .success(content)
    }
}

// MARK: - LockedBuffer

/// Thread-safe byte buffer for accumulating pipe output with a size cap.
private final class LockedBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    private let maxSize: Int

    init(maxSize: Int) {
        self.maxSize = maxSize
    }

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < maxSize else { return }
        let remaining = maxSize - data.count
        data.append(newData.prefix(remaining))
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    var isTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return data.count >= maxSize
    }
}

// MARK: - AtomicFlag

/// Simple atomic boolean flag to ensure a continuation is resumed exactly once.
private final class AtomicFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    /// Returns `true` if this is the first call; `false` on subsequent calls.
    func setIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
