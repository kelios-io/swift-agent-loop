import Testing
import Foundation
@testable import SwiftAgentLoop

@Suite("GrepTool")
struct GrepToolTests {
    let tool = GrepTool()

    private func makeTempDir(files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrepToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            let filePath = dir.appendingPathComponent(name)
            let parent = filePath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try content.write(to: filePath, atomically: true, encoding: .utf8)
        }
        return dir
    }

    // MARK: - 1. files_with_matches mode

    @Test("Default mode returns matching file paths")
    func filesWithMatchesMode() async throws {
        let dir = try makeTempDir(files: [
            "match.txt": "hello world",
            "nomatch.txt": "goodbye",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let result = try await tool.execute(
            input: ["pattern": "hello"],
            context: context
        )
        #expect(result.isError == false)
        #expect(result.content.contains("match.txt"))
        #expect(!result.content.contains("nomatch.txt"))
    }

    // MARK: - 2. Content mode with line numbers

    @Test("Content mode shows matching lines with line numbers")
    func contentModeWithLineNumbers() async throws {
        let dir = try makeTempDir(files: [
            "code.swift": "let x = 1\nlet y = 2\nlet z = 3",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let result = try await tool.execute(
            input: ["pattern": "y = 2", "output_mode": "content"],
            context: context
        )
        #expect(result.isError == false)
        #expect(result.content.contains("2:"))
        #expect(result.content.contains("let y = 2"))
    }

    // MARK: - 3. Count mode

    @Test("Count mode returns match count per file")
    func countMode() async throws {
        let dir = try makeTempDir(files: [
            "repeated.txt": "foo bar\nfoo baz\nqux",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let result = try await tool.execute(
            input: ["pattern": "foo", "output_mode": "count"],
            context: context
        )
        #expect(result.isError == false)
        #expect(result.content.contains("repeated.txt:2"))
    }

    // MARK: - 4. Case-insensitive search

    @Test("Case-insensitive flag matches regardless of case")
    func caseInsensitiveFlag() async throws {
        let dir = try makeTempDir(files: [
            "mixed.txt": "Hello World",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let result = try await tool.execute(
            input: ["pattern": "hello", "-i": true],
            context: context
        )
        #expect(result.isError == false)
        #expect(result.content.contains("mixed.txt"))
    }

    // MARK: - 5. No matches

    @Test("No matches returns informative message")
    func noMatchesMessage() async throws {
        let dir = try makeTempDir(files: [
            "file.txt": "nothing relevant here",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let result = try await tool.execute(
            input: ["pattern": "zzzznotfound"],
            context: context
        )
        #expect(result.isError == false)
        #expect(result.content.contains("No matches found"))
    }

    // MARK: - 6. Invalid regex

    @Test("Invalid regex fails validation")
    func invalidRegexError() throws {
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        #expect(throws: ToolError.self) {
            try tool.validate(input: ["pattern": "["], context: context)
        }
    }

    // MARK: - 7. Glob filter

    @Test("Glob filter restricts search to matching files")
    func globFilter() async throws {
        let dir = try makeTempDir(files: [
            "code.swift": "let value = 42",
            "data.txt": "let value = 42",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let result = try await tool.execute(
            input: ["pattern": "value", "glob": "*.swift"],
            context: context
        )
        #expect(result.isError == false)
        #expect(result.content.contains("code.swift"))
        #expect(!result.content.contains("data.txt"))
    }

    // MARK: - 8. Context lines

    @Test("Context lines include surrounding lines in content mode")
    func contextLines() async throws {
        let dir = try makeTempDir(files: [
            "lines.txt": "aaa\nbbb\nccc\nddd\neee",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let result = try await tool.execute(
            input: ["pattern": "ccc", "output_mode": "content", "-C": 1],
            context: context
        )
        #expect(result.isError == false)
        #expect(result.content.contains("bbb"))
        #expect(result.content.contains("ccc"))
        #expect(result.content.contains("ddd"))
    }
}
