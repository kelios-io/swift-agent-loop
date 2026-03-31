import Testing
import Foundation
@testable import SwiftAgentLoop

@Suite("BashTool")
struct BashToolTests {
    let tool = BashTool()
    let context: ToolContext

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BashToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = ToolContext(workingDirectory: dir)
    }

    // MARK: - 1. Simple command

    @Test("Simple command returns output")
    func simpleCommand() async throws {
        let result = try await tool.execute(
            input: ["command": "echo hello"],
            context: context
        )
        #expect(result.content.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(result.isError == false)
    }

    // MARK: - 2. Exit code handling

    @Test("Non-zero exit code returns error with exit code")
    func exitCodeHandling() async throws {
        let result = try await tool.execute(
            input: ["command": "exit 1"],
            context: context
        )
        #expect(result.isError == true)
        #expect(result.content.contains("Exit code: 1"))
    }

    // MARK: - 3. Working directory

    @Test("pwd returns the configured working directory")
    func workingDirectory() async throws {
        // Use pwd (without -P) to match how bash resolves the directory,
        // which should match what Process sets as currentDirectoryURL.
        let result = try await tool.execute(
            input: ["command": "pwd"],
            context: context
        )
        let actual = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
        // The working directory path should be a suffix of the actual path
        // (macOS may prepend /private to /var or /tmp symlinks)
        #expect(actual.hasSuffix(context.workingDirectory.lastPathComponent))
        #expect(result.isError == false)
    }

    // MARK: - 4. Stderr output

    @Test("Stderr output is included in result")
    func stderrOutput() async throws {
        let result = try await tool.execute(
            input: ["command": "echo out; echo err >&2"],
            context: context
        )
        #expect(result.content.contains("stderr:"))
        #expect(result.content.contains("err"))
        #expect(result.content.contains("out"))
    }

    // MARK: - 5. Timeout enforcement

    @Test("Long-running command is terminated on timeout")
    func timeoutEnforcement() async throws {
        let result = try await tool.execute(
            input: ["command": "sleep 10", "timeout": 1000],
            context: context
        )
        // The process is killed by SIGTERM (exit code 15) on timeout.
        // Depending on timing, the result may say "timed out" or show exit code 15.
        #expect(result.isError == true)
        #expect(result.content.contains("timed out") || result.content.contains("Exit code: 15"))
    }

    // MARK: - 6. Destructive command detection

    @Test("DestructiveDetector flags rm -rf /")
    func detectRmRf() {
        let warning = DestructiveDetector.check(command: "rm -rf /")
        #expect(warning != nil)
    }

    @Test("DestructiveDetector flags git push --force")
    func detectGitPushForce() {
        let warning = DestructiveDetector.check(command: "git push --force")
        #expect(warning != nil)
    }

    @Test("DestructiveDetector flags git reset --hard")
    func detectGitResetHard() {
        let warning = DestructiveDetector.check(command: "git reset --hard")
        #expect(warning != nil)
    }

    @Test("DestructiveDetector allows echo hello")
    func allowEchoHello() {
        let warning = DestructiveDetector.check(command: "echo hello")
        #expect(warning == nil)
    }

    @Test("DestructiveDetector allows ls -la")
    func allowLsLa() {
        let warning = DestructiveDetector.check(command: "ls -la")
        #expect(warning == nil)
    }

    // MARK: - 7. Empty command

    @Test("Empty command fails validation")
    func emptyCommand() throws {
        #expect(throws: ToolError.self) {
            try tool.validate(input: ["command": ""], context: context)
        }
    }

    @Test("Missing command fails validation")
    func missingCommand() throws {
        #expect(throws: ToolError.self) {
            try tool.validate(input: [:], context: context)
        }
    }

    // MARK: - 8. Multi-line output

    @Test("Multi-line output returns all lines")
    func multiLineOutput() async throws {
        let result = try await tool.execute(
            input: ["command": "printf 'line1\\nline2\\nline3'"],
            context: context
        )
        #expect(result.content.contains("line1"))
        #expect(result.content.contains("line2"))
        #expect(result.content.contains("line3"))
        #expect(result.isError == false)
    }
}