import Testing
import Foundation
@testable import SwiftAgentLoop

@Suite("EditTool")
struct EditToolTests {
    let tool = EditTool()
    let context = ToolContext(workingDirectory: URL(fileURLWithPath: "/tmp"))

    /// Creates a temp directory with a test file containing `content`.
    /// Returns (directoryURL, absoluteFilePath).
    private func makeTempFile(content: String) throws -> (URL, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("test.txt")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return (dir, file.path)
    }

    /// Reads the file back and returns its contents.
    private func readFile(at path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    // MARK: - 1. Successful single replacement

    @Test("Replaces a unique old_string with new_string")
    func successfulSingleReplacement() async throws {
        let (dir, path) = try makeTempFile(content: "Hello, world!")
        defer { try? FileManager.default.removeItem(at: dir) }

        let input: [String: Any] = [
            "file_path": path,
            "old_string": "world",
            "new_string": "Swift",
        ]
        try tool.validate(input: input, context: context)
        let result = try await tool.execute(input: input, context: context)

        #expect(!result.isError)
        #expect(try readFile(at: path) == "Hello, Swift!")
    }

    // MARK: - 2. old_string not found

    @Test("Returns error when old_string is not found")
    func oldStringNotFound() async throws {
        let (dir, path) = try makeTempFile(content: "Hello, world!")
        defer { try? FileManager.default.removeItem(at: dir) }

        let input: [String: Any] = [
            "file_path": path,
            "old_string": "missing",
            "new_string": "replacement",
        ]
        try tool.validate(input: input, context: context)
        let result = try await tool.execute(input: input, context: context)

        #expect(result.isError)
        #expect(result.content.contains("not found"))
    }

    // MARK: - 3. old_string not unique

    @Test("Returns error with occurrence count when old_string appears multiple times")
    func oldStringNotUnique() async throws {
        let (dir, path) = try makeTempFile(content: "aaa bbb aaa ccc aaa")
        defer { try? FileManager.default.removeItem(at: dir) }

        let input: [String: Any] = [
            "file_path": path,
            "old_string": "aaa",
            "new_string": "xxx",
            "replace_all": false,
        ]
        try tool.validate(input: input, context: context)
        let result = try await tool.execute(input: input, context: context)

        #expect(result.isError)
        #expect(result.content.contains("3 occurrences"))
        // File should be unchanged
        #expect(try readFile(at: path) == "aaa bbb aaa ccc aaa")
    }

    // MARK: - 4. replace_all works

    @Test("Replaces all occurrences when replace_all is true")
    func replaceAllWorks() async throws {
        let (dir, path) = try makeTempFile(content: "aaa bbb aaa ccc aaa")
        defer { try? FileManager.default.removeItem(at: dir) }

        let input: [String: Any] = [
            "file_path": path,
            "old_string": "aaa",
            "new_string": "xxx",
            "replace_all": true,
        ]
        try tool.validate(input: input, context: context)
        let result = try await tool.execute(input: input, context: context)

        #expect(!result.isError)
        #expect(result.content.contains("3 occurrences"))
        #expect(try readFile(at: path) == "xxx bbb xxx ccc xxx")
    }

    // MARK: - 5. old_string equals new_string

    @Test("Validation fails when old_string equals new_string")
    func oldStringEqualsNewString() throws {
        let input: [String: Any] = [
            "file_path": "/tmp/test.txt",
            "old_string": "same",
            "new_string": "same",
        ]

        #expect(throws: ToolError.self) {
            try tool.validate(input: input, context: context)
        }
    }

    // MARK: - 6. Whitespace preservation

    @Test("Preserves indentation and trailing whitespace exactly")
    func whitespacePreservation() async throws {
        let content = "    func hello() {\n        print(\"hi\")  \n    }\n"
        let (dir, path) = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: dir) }

        let input: [String: Any] = [
            "file_path": path,
            "old_string": "        print(\"hi\")  ",
            "new_string": "        print(\"goodbye\")  ",
        ]
        try tool.validate(input: input, context: context)
        let result = try await tool.execute(input: input, context: context)

        #expect(!result.isError)
        let expected = "    func hello() {\n        print(\"goodbye\")  \n    }\n"
        #expect(try readFile(at: path) == expected)
    }

    // MARK: - 7. Multi-line old_string

    @Test("Replaces a block of multiple lines")
    func multiLineOldString() async throws {
        let content = "line1\nline2\nline3\nline4\nline5\n"
        let (dir, path) = try makeTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: dir) }

        let input: [String: Any] = [
            "file_path": path,
            "old_string": "line2\nline3\nline4",
            "new_string": "replaced2\nreplaced3",
        ]
        try tool.validate(input: input, context: context)
        let result = try await tool.execute(input: input, context: context)

        #expect(!result.isError)
        #expect(try readFile(at: path) == "line1\nreplaced2\nreplaced3\nline5\n")
    }

    // MARK: - 8. Empty new_string (deletion)

    @Test("Empty new_string effectively deletes the old_string")
    func emptyNewStringDeletesContent() async throws {
        let (dir, path) = try makeTempFile(content: "Hello, world!")
        defer { try? FileManager.default.removeItem(at: dir) }

        let input: [String: Any] = [
            "file_path": path,
            "old_string": ", world",
            "new_string": "",
        ]
        try tool.validate(input: input, context: context)
        let result = try await tool.execute(input: input, context: context)

        #expect(!result.isError)
        #expect(try readFile(at: path) == "Hello!")
    }

    // MARK: - 9. File not found

    @Test("Returns error when file does not exist")
    func fileNotFound() async throws {
        let input: [String: Any] = [
            "file_path": "/tmp/EditToolTests-nonexistent-\(UUID().uuidString)/missing.txt",
            "old_string": "hello",
            "new_string": "world",
        ]
        try tool.validate(input: input, context: context)
        let result = try await tool.execute(input: input, context: context)

        #expect(result.isError)
        #expect(result.content.contains("File not found") || result.content.contains("Failed to read"))
    }

    // MARK: - 10. Non-absolute path

    @Test("Validation fails for non-absolute file_path")
    func nonAbsolutePath() throws {
        let input: [String: Any] = [
            "file_path": "relative/path.txt",
            "old_string": "a",
            "new_string": "b",
        ]

        #expect(throws: ToolError.self) {
            try tool.validate(input: input, context: context)
        }
    }
}