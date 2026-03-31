import Foundation

// MARK: - EditTool

/// Performs exact string replacements in files.
///
/// Supports single (unique) replacement or replace-all mode.
/// The uniqueness check ensures edits target the correct location.
public struct EditTool: AgentTool {
    public let name = "Edit"
    public let description = "Performs exact string replacements in files"
    public let isReadOnly = false

    public let inputSchema = InputSchema([
        "type": "object",
        "required": ["file_path", "old_string", "new_string"],
        "properties": [
            "file_path": [
                "type": "string",
                "description": "The absolute path to the file to modify",
            ],
            "old_string": [
                "type": "string",
                "description": "The text to replace",
            ],
            "new_string": [
                "type": "string",
                "description": "The text to replace it with",
            ],
            "replace_all": [
                "type": "boolean",
                "description": "Replace all occurrences of old_string (default false)",
            ],
        ] as [String: Any],
    ])

    public init() {}

    // MARK: - Validation

    public func validate(input: [String: Any], context: ToolContext) throws {
        guard let filePath = input["file_path"] as? String, !filePath.isEmpty else {
            throw ToolError.missingParameter("file_path")
        }
        guard filePath.hasPrefix("/") else {
            throw ToolError.invalidParameter(
                name: "file_path",
                message: "file_path must be an absolute path"
            )
        }
        guard let oldString = input["old_string"] as? String else {
            throw ToolError.missingParameter("old_string")
        }
        guard let newString = input["new_string"] as? String else {
            throw ToolError.missingParameter("new_string")
        }
        guard oldString != newString else {
            throw ToolError.invalidParameter(
                name: "old_string",
                message: "old_string and new_string must be different"
            )
        }
    }

    // MARK: - Execution

    public func execute(input: [String: Any], context: ToolContext) async throws -> ToolResult {
        guard let filePath = input["file_path"] as? String else {
            return .error("file_path is required and must be a string")
        }
        guard let oldString = input["old_string"] as? String else {
            return .error("old_string is required and must be a string")
        }
        guard let newString = input["new_string"] as? String else {
            return .error("new_string is required and must be a string")
        }
        let replaceAll = input["replace_all"] as? Bool ?? false

        let fileURL = URL(fileURLWithPath: filePath)

        // Read current contents
        let contents: String
        do {
            contents = try String(contentsOf: fileURL, encoding: .utf8)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError
        {
            return .error("File not found: \(filePath)")
        } catch {
            return .error("Failed to read file: \(error.localizedDescription)")
        }

        // Count occurrences
        let occurrences = countOccurrences(of: oldString, in: contents)

        if occurrences == 0 {
            return .error("old_string not found in \(filePath)")
        }

        if !replaceAll && occurrences > 1 {
            return .error(
                "old_string is not unique, found \(occurrences) occurrences. "
                    + "Use replace_all or provide more context."
            )
        }

        // Perform replacement
        let newContents: String
        if replaceAll {
            newContents = contents.replacingOccurrences(of: oldString, with: newString)
        } else {
            // Replace only the first (and only) occurrence
            guard let range = contents.range(of: oldString) else {
                return .error("old_string not found in \(filePath)")
            }
            newContents = contents.replacingCharacters(in: range, with: newString)
        }

        // Write back
        do {
            try newContents.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            return .error("Failed to write file: \(error.localizedDescription)")
        }

        // Build output with context snippet
        let snippet = buildSnippet(
            fileContents: newContents,
            newString: newString,
            contextLines: 3
        )
        let replacementCount = replaceAll ? occurrences : 1
        let summary =
            replacementCount == 1
            ? "Replaced 1 occurrence in \(filePath)"
            : "Replaced \(replacementCount) occurrences in \(filePath)"

        return .success("\(summary)\n\n\(snippet)")
    }

    // MARK: - Helpers

    /// Counts non-overlapping occurrences of `needle` in `haystack`.
    private func countOccurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }
        return count
    }

    /// Builds a snippet showing the replacement with surrounding context lines.
    private func buildSnippet(
        fileContents: String,
        newString: String,
        contextLines: Int
    ) -> String {
        let lines = fileContents.components(separatedBy: "\n")

        // Find the line range containing the new string
        guard let firstMatchRange = fileContents.range(of: newString) else {
            // new_string might be empty (deletion) — just confirm
            return "(content deleted)"
        }

        // Count newlines before match to find the line number
        let prefix = fileContents[fileContents.startIndex..<firstMatchRange.lowerBound]
        let matchStartLine = prefix.filter { $0 == "\n" }.count

        let matchContent = fileContents[firstMatchRange]
        let matchLineCount = matchContent.filter { $0 == "\n" }.count

        let snippetStart = max(0, matchStartLine - contextLines)
        let snippetEnd = min(lines.count - 1, matchStartLine + matchLineCount + contextLines)

        var snippet = ""
        for i in snippetStart...snippetEnd {
            let lineNum = String(i + 1).padding(toLength: 4, withPad: " ", startingAt: 0)
            snippet += "\(lineNum)| \(lines[i])\n"
        }

        return snippet
    }
}