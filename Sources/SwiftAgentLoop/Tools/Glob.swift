import Foundation

// MARK: - GlobTool

/// Searches for files matching a glob pattern within a directory.
/// Supports recursive matching with `**` and standard glob patterns.
public struct GlobTool: AgentTool, Sendable {

    public let name = "Glob"

    public let description = "Fast file pattern matching tool. Supports glob patterns like \"**/*.swift\" or \"src/**/*.ts\". Returns matching file paths sorted by modification time (newest first)."

    public let isReadOnly = true
    public let isConcurrencySafe = true

    public let inputSchema = InputSchema([
        "type": "object",
        "properties": [
            "pattern": [
                "type": "string",
                "description": "The glob pattern to match files against (e.g. \"**/*.swift\", \"src/**/*.ts\")"
            ],
            "path": [
                "type": "string",
                "description": "The directory to search in. Defaults to working directory if not specified."
            ]
        ],
        "required": ["pattern"]
    ])

    public init() {}

    public func validate(input: [String: Any], context: ToolContext) throws {
        guard let pattern = input["pattern"] as? String, !pattern.isEmpty else {
            throw ToolError.missingParameter("pattern")
        }
    }

    public func execute(input: [String: Any], context: ToolContext) async throws -> ToolResult {
        let pattern = input["pattern"] as! String

        let baseURL: URL
        if let pathString = input["path"] as? String, !pathString.isEmpty {
            if pathString.hasPrefix("/") {
                baseURL = URL(fileURLWithPath: pathString)
            } else {
                baseURL = context.workingDirectory.appendingPathComponent(pathString)
            }
        } else {
            baseURL = context.workingDirectory
        }

        // Verify base path exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: baseURL.path, isDirectory: &isDir), isDir.boolValue else {
            return .error("Directory not found: \(baseURL.path)")
        }

        // Parse the pattern into prefix and filename portions around **
        let parsed = parsePattern(pattern)

        // Enumerate all files recursively
        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .error("Failed to enumerate directory: \(baseURL.path)")
        }

        struct MatchedFile {
            let path: String
            let modDate: Date
        }

        var matches: [MatchedFile] = []
        let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"

        while let fileURL = enumerator.nextObject() as? URL {
            // Only match regular files
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            let fullPath = fileURL.path
            // Get relative path from base
            guard fullPath.hasPrefix(basePath) else { continue }
            let relativePath = String(fullPath.dropFirst(basePath.count))

            if matchesGlob(relativePath: relativePath, parsed: parsed) {
                let modDate = resourceValues.contentModificationDate ?? .distantPast
                matches.append(MatchedFile(path: fullPath, modDate: modDate))
            }
        }

        // Sort by modification time, newest first
        matches.sort { $0.modDate > $1.modDate }

        if matches.isEmpty {
            return .success("No files matched pattern: \(pattern)")
        }

        let result = matches.map(\.path).joined(separator: "\n")
        return .success(result)
    }

    // MARK: - Pattern Parsing

    /// Parsed glob pattern representation
    private struct ParsedPattern {
        /// Directory prefix before ** (e.g. "src/" for "src/**/*.ts"), nil if none
        let prefix: String?
        /// Whether the pattern contains ** (recursive matching)
        let isRecursive: Bool
        /// The filename glob portion (e.g. "*.swift", "*.ts")
        let filePattern: String?
        /// The raw pattern for non-** patterns
        let rawPattern: String
    }

    private func parsePattern(_ pattern: String) -> ParsedPattern {
        let raw = pattern

        // Handle patterns with **
        if pattern.contains("**") {
            let components = pattern.components(separatedBy: "**")

            // Prefix: everything before **
            var prefix: String? = nil
            let rawPrefix = components[0]
            if !rawPrefix.isEmpty {
                // Remove trailing /
                prefix = rawPrefix.hasSuffix("/") ? String(rawPrefix.dropLast()) : rawPrefix
            }

            // File pattern: everything after **
            var filePattern: String? = nil
            if components.count > 1 {
                let rawSuffix = components[1]
                // Remove leading /
                let suffix = rawSuffix.hasPrefix("/") ? String(rawSuffix.dropFirst()) : rawSuffix
                if !suffix.isEmpty {
                    filePattern = suffix
                }
            }

            return ParsedPattern(prefix: prefix, isRecursive: true, filePattern: filePattern, rawPattern: raw)
        }

        // Non-recursive pattern: match against full relative path
        return ParsedPattern(prefix: nil, isRecursive: false, filePattern: nil, rawPattern: raw)
    }

    // MARK: - Matching

    private func matchesGlob(relativePath: String, parsed: ParsedPattern) -> Bool {
        if parsed.isRecursive {
            // Check prefix if present (e.g. "src" in "src/**/*.ts")
            if let prefix = parsed.prefix {
                guard relativePath.hasPrefix(prefix + "/") || relativePath == prefix else {
                    return false
                }
            }

            // Match file pattern against the basename
            if let filePattern = parsed.filePattern {
                // The filePattern may contain path separators (e.g. "dir/*.ts")
                // For simplicity, match against the last N path components
                let patternComponents = filePattern.components(separatedBy: "/")
                let pathComponents = relativePath.components(separatedBy: "/")

                if patternComponents.count > pathComponents.count {
                    return false
                }

                // Match the last N components of the path against the pattern components
                let pathSuffix = Array(pathComponents.suffix(patternComponents.count))
                for (pathComp, patternComp) in zip(pathSuffix, patternComponents) {
                    if fnmatch(patternComp, pathComp, 0) != 0 {
                        return false
                    }
                }
                return true
            }

            // ** with no file pattern: match everything under prefix
            return true
        }

        // Non-recursive: use fnmatch on the full relative path
        return fnmatch(parsed.rawPattern, relativePath, 0) == 0
    }
}