import Testing
import Foundation
@testable import SwiftAgentLoop

@Suite("GlobTool")
struct GlobToolTests {
    let tool = GlobTool()

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlobToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 1. Match *.swift

    @Test("Matches *.swift pattern and excludes other extensions")
    func matchStarDotSwift() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        try "".write(to: dir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let result = try await tool.execute(
            input: ["pattern": "*.swift"],
            context: context
        )
        #expect(result.isError == false)
        #expect(result.content.contains("a.swift"))
        #expect(!result.content.contains("b.txt"))
    }

    // MARK: - 2. Recursive **/*.txt

    @Test("Recursive **/*.txt finds files in subdirectories")
    func recursivePattern() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "".write(to: dir.appendingPathComponent("top.txt"), atomically: true, encoding: .utf8)
        try "".write(to: sub.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)

        let result = try await tool.execute(
            input: ["pattern": "**/*.txt"],
            context: context
        )
        #expect(result.isError == false)
        #expect(result.content.contains("top.txt"))
        #expect(result.content.contains("nested.txt"))
    }

    // MARK: - 3. No matches

    @Test("No matches returns informative message")
    func noMatches() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let result = try await tool.execute(
            input: ["pattern": "*.xyz"],
            context: context
        )
        #expect(result.isError == false)
        #expect(result.content.contains("No files matched"))
    }

    // MARK: - 4. Empty pattern validation

    @Test("Empty pattern fails validation")
    func emptyPatternValidation() throws {
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        #expect(throws: ToolError.self) {
            try tool.validate(input: ["pattern": ""], context: context)
        }
    }

    // MARK: - 5. Non-existent directory

    @Test("Non-existent directory returns error")
    func nonExistentDirectory() async throws {
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)

        let result = try await tool.execute(
            input: ["pattern": "*.swift", "path": "/nonexistent/dir/\(UUID().uuidString)"],
            context: context
        )
        #expect(result.isError == true)
        #expect(result.content.contains("not found"))
    }
}
