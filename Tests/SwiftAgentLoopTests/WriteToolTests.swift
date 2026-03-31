import Testing
import Foundation
@testable import SwiftAgentLoop

@Suite("WriteTool")
struct WriteToolTests {
    let tool = WriteTool()

    // MARK: - 1. Write new file

    @Test("Write creates a new file with correct content")
    func writeNewFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriteToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)
        let filePath = dir.appendingPathComponent("new.txt").path

        let result = try await tool.execute(
            input: ["file_path": filePath, "content": "hello world"],
            context: context
        )
        #expect(result.isError == false)
        let written = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(written == "hello world")
    }

    // MARK: - 2. Overwrite existing file

    @Test("Write overwrites existing file")
    func overwriteExistingFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriteToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)
        let filePath = dir.appendingPathComponent("overwrite.txt").path

        try "original".write(toFile: filePath, atomically: true, encoding: .utf8)

        let result = try await tool.execute(
            input: ["file_path": filePath, "content": "replaced"],
            context: context
        )
        #expect(result.isError == false)
        let written = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(written == "replaced")
    }

    // MARK: - 3. Creates parent directories

    @Test("Write creates parent directories automatically")
    func createsParentDirectories() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriteToolTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)
        let filePath = dir.appendingPathComponent("deep/nested/dir/file.txt").path

        let result = try await tool.execute(
            input: ["file_path": filePath, "content": "nested content"],
            context: context
        )
        #expect(result.isError == false)
        #expect(FileManager.default.fileExists(atPath: filePath))
    }

    // MARK: - 4. Missing file_path validation

    @Test("Missing file_path fails validation")
    func missingFilePath() throws {
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        #expect(throws: ToolError.self) {
            try tool.validate(input: ["content": "data"], context: context)
        }
    }

    // MARK: - 5. Non-absolute path validation

    @Test("Relative path fails validation")
    func nonAbsolutePathValidation() throws {
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        #expect(throws: ToolError.self) {
            try tool.validate(
                input: ["file_path": "relative/path.txt", "content": "data"],
                context: context
            )
        }
    }
}
