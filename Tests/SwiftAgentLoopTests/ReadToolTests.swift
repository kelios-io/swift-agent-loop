import Testing
import Foundation
@testable import SwiftAgentLoop

@Suite("ReadTool")
struct ReadToolTests {
    let tool = ReadTool()

    private func makeTempFile(content: String) throws -> (dir: URL, path: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("test.txt")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return (dir, file.path)
    }

    // MARK: - 1. Read file with line numbers

    @Test("Read file returns content with line numbers")
    func readFileWithLineNumbers() async throws {
        let (dir, path) = try makeTempFile(content: "alpha\nbeta\ngamma")
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let result = try await tool.execute(input: ["file_path": path], context: context)
        #expect(result.isError == false)
        #expect(result.content.contains("1\t"))
        #expect(result.content.contains("alpha"))
        #expect(result.content.contains("beta"))
        #expect(result.content.contains("gamma"))
    }

    // MARK: - 2. Offset and limit

    @Test("Offset and limit restrict returned lines")
    func offsetAndLimit() async throws {
        let lines = (1...10).map { "line\($0)" }.joined(separator: "\n")
        let (dir, path) = try makeTempFile(content: lines)
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let result = try await tool.execute(
            input: ["file_path": path, "offset": 3, "limit": 2],
            context: context
        )
        #expect(result.isError == false)
        #expect(result.content.contains("line3"))
        #expect(result.content.contains("line4"))
        #expect(!result.content.contains("line2"))
        #expect(!result.content.contains("line5"))
    }

    // MARK: - 3. File not found

    @Test("Non-existent file returns error")
    func fileNotFound() async throws {
        let dir = FileManager.default.temporaryDirectory
        let context = ToolContext(workingDirectory: dir)

        let result = try await tool.execute(
            input: ["file_path": "/nonexistent/path/file.txt"],
            context: context
        )
        #expect(result.isError == true)
        #expect(result.content.contains("File not found"))
    }

    // MARK: - 4. Binary file detection

    @Test("Binary file returns error")
    func binaryFileDetection() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let file = dir.appendingPathComponent("binary.bin")
        var data = Data("hello".utf8)
        data.append(0x00) // null byte
        data.append(Data("world".utf8))
        try data.write(to: file)

        let result = try await tool.execute(
            input: ["file_path": file.path],
            context: context
        )
        #expect(result.isError == true)
        #expect(result.content.contains("binary"))
    }

    // MARK: - 5. Directory path error

    @Test("Directory path returns error")
    func directoryPathError() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let result = try await tool.execute(
            input: ["file_path": dir.path],
            context: context
        )
        #expect(result.isError == true)
        #expect(result.content.contains("directory"))
    }

    // MARK: - 6. Non-absolute path validation

    @Test("Relative path fails validation")
    func nonAbsolutePathValidation() throws {
        let context = ToolContext(workingDirectory: FileManager.default.temporaryDirectory)
        #expect(throws: ToolError.self) {
            try tool.validate(input: ["file_path": "relative/path.txt"], context: context)
        }
    }

    // MARK: - 7. Offset beyond EOF

    @Test("Offset beyond file length returns error")
    func offsetBeyondEOF() async throws {
        let (dir, path) = try makeTempFile(content: "one\ntwo\nthree")
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = ToolContext(workingDirectory: dir)

        let result = try await tool.execute(
            input: ["file_path": path, "offset": 100],
            context: context
        )
        #expect(result.isError == true)
        #expect(result.content.contains("beyond"))
    }
}
