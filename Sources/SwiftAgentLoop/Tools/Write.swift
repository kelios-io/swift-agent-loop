import Foundation

/// Tool that writes content to a file, creating parent directories as needed.
public struct WriteTool: AgentTool {
    public let name = "Write"
    public let description = "Writes content to a file at the specified absolute path, creating parent directories if needed."
    public let isReadOnly = false

    public let inputSchema = InputSchema([
        "type": "object",
        "properties": [
            "file_path": [
                "type": "string",
                "description": "The absolute path to the file to write"
            ],
            "content": [
                "type": "string",
                "description": "The content to write to the file"
            ]
        ],
        "required": ["file_path", "content"]
    ])

    public init() {}

    public func validate(input: [String: Any], context: ToolContext) throws {
        guard let filePath = input["file_path"] as? String, !filePath.isEmpty else {
            throw ToolError.missingParameter("file_path")
        }
        guard input["content"] is String else {
            throw ToolError.missingParameter("content")
        }
        guard filePath.hasPrefix("/") else {
            throw ToolError.invalidParameter(
                name: "file_path",
                message: "Path must be absolute (start with /): \(filePath)"
            )
        }
    }

    public func execute(input: [String: Any], context: ToolContext) async throws -> ToolResult {
        do {
            try validate(input: input, context: context)
        } catch let error as ToolError {
            switch error {
            case .missingParameter(let name):
                return .error("Missing required parameter: \(name)")
            case .invalidParameter(_, let message):
                return .error(message)
            default:
                return .error("\(error)")
            }
        }

        let filePath = input["file_path"] as! String
        let content = input["content"] as! String
        let fileURL = URL(fileURLWithPath: filePath)
        let parentDirectory = fileURL.deletingLastPathComponent()

        // Create parent directories if needed
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: parentDirectory.path) {
            do {
                try fileManager.createDirectory(
                    at: parentDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                return .error("Failed to create directory \(parentDirectory.path): \(error.localizedDescription)")
            }
        }

        // Write content
        guard let data = content.data(using: .utf8) else {
            return .error("Failed to encode content as UTF-8")
        }

        do {
            try data.write(to: fileURL)
        } catch {
            return .error("Failed to write to \(filePath): \(error.localizedDescription)")
        }

        return .success("Successfully wrote \(data.count) bytes to \(filePath)")
    }
}