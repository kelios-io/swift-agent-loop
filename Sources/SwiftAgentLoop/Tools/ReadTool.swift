import Foundation

/// Reads files from the local filesystem with line numbers.
/// Port of Claude Code's FileReadTool.
public struct ReadTool: AgentTool {
    public let name = "Read"
    public let description = "Reads a file from the local filesystem."
    public let isReadOnly = true
    public let isConcurrencySafe = true

    public var inputSchema: InputSchema {
        InputSchema([
            "type": "object",
            "properties": [
                "file_path": [
                    "type": "string",
                    "description": "The absolute path to the file to read",
                ],
                "offset": [
                    "type": "number",
                    "description":
                        "The line number to start reading from. Only provide if the file is too large to read at once",
                ],
                "limit": [
                    "type": "number",
                    "description":
                        "The number of lines to read. Only provide if the file is too large to read at once.",
                ],
            ],
            "required": ["file_path"],
            "additionalProperties": false,
        ])
    }

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
    }

    // MARK: - Execution

    public func execute(input: [String: Any], context: ToolContext) async throws -> ToolResult {
        guard let filePath = input["file_path"] as? String else {
            return .error("file_path is required")
        }
        guard filePath.hasPrefix("/") else {
            return .error("file_path must be an absolute path")
        }

        let url = URL(fileURLWithPath: filePath)
        let fileManager = FileManager.default

        // Check file exists
        guard fileManager.fileExists(atPath: filePath) else {
            return .error("File not found: \(filePath)")
        }

        // Check it's not a directory
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            return .error(
                "\(filePath) is a directory, not a file. Use Bash with ls to list directory contents."
            )
        }

        // Binary detection: check first 8KB for null bytes
        if let fileHandle = FileHandle(forReadingAtPath: filePath) {
            defer { fileHandle.closeFile() }
            let headerData = fileHandle.readData(ofLength: 8192)
            if headerData.contains(0x00) {
                return .error(
                    "This is a binary file and cannot be displayed as text. Use a Bash command to examine it instead."
                )
            }
        }

        // Read file content
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Latin1 fallback
            do {
                content = try String(contentsOf: url, encoding: .isoLatin1)
            } catch {
                return .error("Failed to read file: \(error.localizedDescription)")
            }
        }

        let allLines = content.components(separatedBy: "\n")

        // Parse offset (1-based) and limit
        let offset: Int
        if let rawOffset = input["offset"] {
            if let intVal = rawOffset as? Int {
                offset = max(intVal, 1)
            } else if let doubleVal = rawOffset as? Double {
                offset = max(Int(doubleVal), 1)
            } else {
                offset = 1
            }
        } else {
            offset = 1
        }

        let limit: Int
        if let rawLimit = input["limit"] {
            if let intVal = rawLimit as? Int {
                limit = max(intVal, 1)
            } else if let doubleVal = rawLimit as? Double {
                limit = max(Int(doubleVal), 1)
            } else {
                limit = 2000
            }
        } else {
            limit = 2000
        }

        // Size check: if file > 256KB and no offset/limit specified, warn
        if let attrs = try? fileManager.attributesOfItem(atPath: filePath),
            let fileSize = attrs[.size] as? UInt64,
            fileSize > 256 * 1024,
            input["offset"] == nil, input["limit"] == nil
        {
            // Still read with default limit, but add a note
            let startIndex = max(offset - 1, 0)
            let endIndex = min(startIndex + limit, allLines.count)
            guard startIndex < allLines.count else {
                return .error(
                    "Offset \(offset) is beyond the end of the file (\(allLines.count) lines)"
                )
            }
            let selectedLines = Array(allLines[startIndex..<endIndex])
            let formatted = formatLines(selectedLines, startingAt: startIndex + 1)
            let note =
                "Note: File is larger than 256KB (\(allLines.count) lines total). Showing first \(limit) lines. Use offset and limit parameters to read specific sections.\n\n"
            return .success(note + formatted)
        }

        // Apply offset and limit
        let startIndex = max(offset - 1, 0)
        let endIndex = min(startIndex + limit, allLines.count)

        guard startIndex < allLines.count else {
            return .error(
                "Offset \(offset) is beyond the end of the file (\(allLines.count) lines)"
            )
        }

        let selectedLines = Array(allLines[startIndex..<endIndex])
        let formatted = formatLines(selectedLines, startingAt: startIndex + 1)
        return .success(formatted)
    }

    // MARK: - Private

    /// Formats lines with right-aligned line numbers like `cat -n`.
    private func formatLines(_ lines: [String], startingAt lineNumber: Int) -> String {
        let lastLineNumber = lineNumber + lines.count - 1
        let width = String(lastLineNumber).count
        let minWidth = max(width, 6)

        var result = ""
        result.reserveCapacity(lines.count * 80)

        for (index, line) in lines.enumerated() {
            let num = lineNumber + index
            let numStr = String(num)
            let padding = String(repeating: " ", count: minWidth - numStr.count)
            result += "\(padding)\(numStr)\t\(line)\n"
        }

        return result
    }
}