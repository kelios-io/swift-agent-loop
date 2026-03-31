import Foundation

// MARK: - GrepTool

/// Searches files for regex pattern matches, similar to ripgrep.
/// Supports multiple output modes, file filtering, and context lines.
public struct GrepTool: AgentTool, Sendable {
    public let name = "Grep"
    public let description = "Search files for regex pattern matches with filtering and multiple output modes"
    public let isReadOnly = true
    public let isConcurrencySafe = true

    public init() {}

    // MARK: - Input Schema

    public var inputSchema: InputSchema {
        InputSchema([
            "type": "object",
            "required": ["pattern"],
            "properties": [
                "pattern": [
                    "type": "string",
                    "description": "Regular expression pattern to search for",
                ],
                "path": [
                    "type": "string",
                    "description": "File or directory to search in (defaults to working directory)",
                ],
                "glob": [
                    "type": "string",
                    "description": "Glob pattern to filter files (e.g. \"*.swift\")",
                ],
                "output_mode": [
                    "type": "string",
                    "enum": ["content", "files_with_matches", "count"],
                    "description": "Output mode (default: files_with_matches)",
                ],
                "-i": [
                    "type": "boolean",
                    "description": "Case insensitive search",
                ],
                "-n": [
                    "type": "boolean",
                    "description": "Show line numbers (default true for content mode)",
                ],
                "-A": [
                    "type": "integer",
                    "description": "Number of lines to show after each match",
                ],
                "-B": [
                    "type": "integer",
                    "description": "Number of lines to show before each match",
                ],
                "-C": [
                    "type": "integer",
                    "description": "Number of context lines before and after each match",
                ],
                "type": [
                    "type": "string",
                    "description": "File type filter (e.g. \"swift\", \"ts\", \"py\")",
                ],
                "head_limit": [
                    "type": "integer",
                    "description": "Limit output entries (default 250)",
                ],
            ],
        ])
    }

    // MARK: - Validation

    public func validate(input: [String: Any], context: ToolContext) throws {
        guard let pattern = input["pattern"] as? String, !pattern.isEmpty else {
            throw ToolError.missingParameter("pattern")
        }

        // Validate regex compiles
        var options: NSRegularExpression.Options = []
        if input["-i"] as? Bool == true {
            options.insert(.caseInsensitive)
        }
        do {
            _ = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw ToolError.invalidParameter(
                name: "pattern",
                message: "Invalid regex: \(error.localizedDescription)"
            )
        }

        // Validate output_mode if provided
        if let mode = input["output_mode"] as? String,
            !["content", "files_with_matches", "count"].contains(mode)
        {
            throw ToolError.invalidParameter(
                name: "output_mode",
                message: "Must be one of: content, files_with_matches, count"
            )
        }
    }

    // MARK: - Execution

    public func execute(input: [String: Any], context: ToolContext) async throws -> ToolResult {
        let pattern = input["pattern"] as! String
        let caseInsensitive = input["-i"] as? Bool ?? false
        let outputMode = input["output_mode"] as? String ?? "files_with_matches"
        let showLineNumbers = input["-n"] as? Bool ?? (outputMode == "content")
        let headLimit = input["head_limit"] as? Int ?? 250
        let globFilter = input["glob"] as? String
        let typeFilter = input["type"] as? String

        // Context lines: -C overrides -A/-B
        let contextLines = input["-C"] as? Int
        let linesAfter = contextLines ?? (input["-A"] as? Int)
        let linesBefore = contextLines ?? (input["-B"] as? Int)

        // Compile regex
        var regexOptions: NSRegularExpression.Options = []
        if caseInsensitive {
            regexOptions.insert(.caseInsensitive)
        }
        let regex = try NSRegularExpression(pattern: pattern, options: regexOptions)

        // Resolve search path
        let searchPath: URL
        if let pathStr = input["path"] as? String {
            let url = URL(fileURLWithPath: pathStr)
            searchPath = url.path.hasPrefix("/") ? url : context.workingDirectory.appendingPathComponent(pathStr)
        } else {
            searchPath = context.workingDirectory
        }

        // Resolve glob from type filter
        let effectiveGlob = globFilter ?? typeFilter.flatMap { fileTypeToGlob($0) }

        // Collect files to search
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: searchPath.path, isDirectory: &isDir) else {
            return .error("Path not found: \(searchPath.path)")
        }

        let filePaths: [URL]
        if isDir.boolValue {
            filePaths = collectFiles(in: searchPath, glob: effectiveGlob, fileManager: fm)
        } else {
            filePaths = [searchPath]
        }

        // Search files and build output
        var output: [String] = []
        var entryCount = 0

        for fileURL in filePaths {
            if entryCount >= headLimit { break }

            guard let data = fm.contents(atPath: fileURL.path),
                let content = String(data: data, encoding: .utf8)
            else {
                continue
            }

            let lines = content.components(separatedBy: "\n")
            let nsContent = content as NSString
            let matches = regex.matches(
                in: content, range: NSRange(location: 0, length: nsContent.length))

            if matches.isEmpty { continue }

            // Find which lines have matches
            var matchingLineIndices = Set<Int>()
            for match in matches {
                guard let range = Range(match.range, in: content) else { continue }
                let prefix = content[content.startIndex..<range.lowerBound]
                let lineIndex = prefix.filter { $0 == "\n" }.count
                matchingLineIndices.insert(lineIndex)
            }

            let relativePath = relativePathString(fileURL, relativeTo: context.workingDirectory)

            switch outputMode {
            case "files_with_matches":
                output.append(relativePath)
                entryCount += 1

            case "count":
                output.append("\(relativePath):\(matchingLineIndices.count)")
                entryCount += 1

            case "content":
                // Determine which lines to include (matches + context)
                var linesToShow = Set<Int>()
                for idx in matchingLineIndices {
                    let before = linesBefore ?? 0
                    let after = linesAfter ?? 0
                    for i in max(0, idx - before)...min(lines.count - 1, idx + after) {
                        linesToShow.insert(i)
                    }
                }

                let sortedLines = linesToShow.sorted()
                var fileOutput: [String] = []
                var prevLine = -2

                for lineIdx in sortedLines {
                    if entryCount >= headLimit { break }

                    // Insert separator for non-contiguous ranges
                    if lineIdx > prevLine + 1 && prevLine >= 0 {
                        fileOutput.append("--")
                    }

                    let prefix: String
                    if showLineNumbers {
                        let separator = matchingLineIndices.contains(lineIdx) ? ":" : "-"
                        prefix = "\(lineIdx + 1)\(separator)"
                    } else {
                        prefix = ""
                    }

                    fileOutput.append("\(prefix)\(lines[lineIdx])")
                    entryCount += 1
                    prevLine = lineIdx
                }

                if !fileOutput.isEmpty {
                    output.append("\(relativePath)")
                    output.append(contentsOf: fileOutput)
                    output.append("")  // blank line between files
                }

            default:
                break
            }
        }

        if output.isEmpty {
            return .success("No matches found.")
        }

        return .success(output.joined(separator: "\n"))
    }

    // MARK: - Private Helpers

    /// Maps file type shorthand to a glob pattern.
    private func fileTypeToGlob(_ type: String) -> String? {
        let mapping: [String: String] = [
            "swift": "*.swift",
            "ts": "*.ts",
            "tsx": "*.tsx",
            "js": "*.js",
            "jsx": "*.jsx",
            "py": "*.py",
            "rust": "*.rs",
            "rs": "*.rs",
            "go": "*.go",
            "java": "*.java",
            "c": "*.c",
            "cpp": "*.cpp",
            "h": "*.h",
            "rb": "*.rb",
            "sh": "*.sh",
            "json": "*.json",
            "yaml": "*.yaml",
            "yml": "*.yml",
            "md": "*.md",
            "html": "*.html",
            "css": "*.css",
        ]
        return mapping[type]
    }

    /// Collects files from a directory, optionally filtering by glob pattern.
    private func collectFiles(in directory: URL, glob: String?, fileManager fm: FileManager) -> [URL]
    {
        guard
            let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return []
        }

        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            // Skip directories
            guard
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                continue
            }

            // Apply glob filter
            if let glob = glob {
                let fileName = url.lastPathComponent
                if !matchesGlob(fileName, pattern: glob) {
                    continue
                }
            }

            // Skip likely binary files
            let ext = url.pathExtension.lowercased()
            if binaryExtensions.contains(ext) {
                continue
            }

            files.append(url)
        }

        return files.sorted { $0.path < $1.path }
    }

    /// Simple glob matching supporting * and ? wildcards.
    private func matchesGlob(_ string: String, pattern: String) -> Bool {
        // Convert glob to regex: escape special chars, replace * and ?
        var regexPattern = NSRegularExpression.escapedPattern(for: pattern)
        regexPattern = regexPattern.replacingOccurrences(of: "\\*", with: ".*")
        regexPattern = regexPattern.replacingOccurrences(of: "\\?", with: ".")
        regexPattern = "^\(regexPattern)$"

        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: .caseInsensitive)
        else {
            return false
        }
        let range = NSRange(location: 0, length: (string as NSString).length)
        return regex.firstMatch(in: string, range: range) != nil
    }

    /// Returns a path string relative to the base directory.
    private func relativePathString(_ url: URL, relativeTo base: URL) -> String {
        let filePath: String
        if let rp = realpath(url.path, nil) {
            filePath = String(cString: rp)
            free(rp)
        } else {
            filePath = url.path
        }
        let resolvedBase: String
        if let rp = realpath(base.path, nil) {
            resolvedBase = String(cString: rp)
            free(rp)
        } else {
            resolvedBase = base.path
        }
        let basePath = resolvedBase.hasSuffix("/") ? resolvedBase : resolvedBase + "/"
        if filePath.hasPrefix(basePath) {
            return String(filePath.dropFirst(basePath.count))
        }
        return filePath
    }

    /// File extensions considered binary (skip during search).
    private let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "ico", "webp", "svg",
        "pdf", "zip", "gz", "tar", "bz2", "xz", "7z", "rar",
        "exe", "dll", "so", "dylib", "o", "a", "lib",
        "mp3", "mp4", "wav", "avi", "mov", "mkv",
        "ttf", "otf", "woff", "woff2", "eot",
        "sqlite", "db", "dmg", "iso",
        "class", "pyc", "pyo",
        "DS_Store",
    ]
}