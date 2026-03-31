import Foundation

/// Creates and manages a temporary directory with a large file tree for Glob/Grep benchmarks.
struct FileTreeFixture {
    let rootDir: URL
    let singleFilePath: String

    /// Create a temp directory with `fileCount` files across nested directories.
    /// Each file has `linesPerFile` lines of code-like content.
    static func create(fileCount: Int = 10_000, linesPerFile: Int = 10) throws -> FileTreeFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftAgentLoop-Bench-\(UUID().uuidString)")

        let fm = FileManager.default
        let dirs = ["src", "src/models", "src/views", "src/utils", "lib", "lib/core", "tests", "tests/unit", "docs", "config"]

        for dir in dirs {
            try fm.createDirectory(
                at: root.appendingPathComponent(dir),
                withIntermediateDirectories: true
            )
        }

        let extensions = ["swift", "ts", "py", "go", "rs", "txt", "json", "md"]
        var singleFile = ""

        for i in 0..<fileCount {
            let dir = dirs[i % dirs.count]
            let ext = extensions[i % extensions.count]
            let fileName = "file_\(i).\(ext)"
            let filePath = root.appendingPathComponent(dir).appendingPathComponent(fileName)

            var content = ""
            for line in 0..<linesPerFile {
                content += "// line \(line) of \(fileName) — func process_\(i)_\(line)() { return \(i * line) }\n"
            }
            try content.write(to: filePath, atomically: false, encoding: .utf8)

            if i == 0 {
                singleFile = filePath.path
            }
        }

        // Create a 1000-line file for ReadTool benchmark
        let readBenchFile = root.appendingPathComponent("read_bench.txt")
        var readContent = ""
        for line in 1...1000 {
            readContent += "Line \(line): This is a test line with some content for benchmarking the ReadTool implementation.\n"
        }
        try readContent.write(to: readBenchFile, atomically: false, encoding: .utf8)

        return FileTreeFixture(rootDir: root, singleFilePath: readBenchFile.path)
    }

    /// Clean up the temporary directory.
    func cleanup() {
        try? FileManager.default.removeItem(at: rootDir)
    }
}
