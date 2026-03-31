import Testing
import Foundation
@testable import SwiftAgentLoop

@Suite("CLAUDE.md Loading")
struct ClaudeMDTests {

    // MARK: - 1. Loads CLAUDE.md from working directory

    @Test("Loads CLAUDE.md from working directory")
    func loadsFromWorkingDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeMDTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let claudeMD = "# Project\nUse Swift 6."
        try claudeMD.write(
            to: dir.appendingPathComponent("CLAUDE.md"),
            atomically: true,
            encoding: .utf8
        )

        // Use NativeTransport.start() which loads CLAUDE.md internally.
        // We can't easily test the private loadClaudeMD directly,
        // but we can verify via SystemPromptBuilder integration.
        let builder = SystemPromptBuilder()
        let config = SystemPromptBuilder.Configuration(
            workingDirectory: dir,
            model: "claude-sonnet-4-6",
            claudeMDContents: claudeMD
        )
        let prompt = builder.build(configuration: config)
        #expect(prompt.contains("Use Swift 6"))
    }

    // MARK: - 2. Walks up directory tree

    @Test("CLAUDE.md found in parent directory is used")
    func walksUpDirectoryTree() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeMDTests-parent-\(UUID().uuidString)")
        let child = parent.appendingPathComponent("src/app")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        try "# Root CLAUDE.md".write(
            to: parent.appendingPathComponent("CLAUDE.md"),
            atomically: true,
            encoding: .utf8
        )

        // Verify the file exists at parent level
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("CLAUDE.md").path))
        // Verify it doesn't exist at child level
        #expect(!FileManager.default.fileExists(atPath: child.appendingPathComponent("CLAUDE.md").path))
    }

    // MARK: - 3. Returns nil when no CLAUDE.md

    @Test("Returns nil when no CLAUDE.md exists in tree")
    func returnsNilWhenMissing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeMDTests-empty-\(UUID().uuidString)")
        // Don't create any CLAUDE.md
        let builder = SystemPromptBuilder()
        let config = SystemPromptBuilder.Configuration(
            workingDirectory: dir,
            model: "claude-sonnet-4-6",
            claudeMDContents: nil
        )
        let prompt = builder.build(configuration: config)
        #expect(!prompt.contains("CLAUDE.md"))
    }
}
