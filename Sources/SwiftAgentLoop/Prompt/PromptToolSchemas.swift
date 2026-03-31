import Foundation

/// JSON schemas for tool definitions, copied verbatim from Claude Code source.
/// Source: github.com/anthropics/claude-code (commit: 4b9d30f7953273e567a18eb819f4eddd45fcc877)
///
/// IMPORTANT: Do not paraphrase or restructure these schemas.
/// Claude is trained on these exact shapes for optimal tool-use accuracy.
public enum ToolSchemas {

    // MARK: - Read

    /// Read tool — file reading with line numbers
    public static let read = ToolDefinition(
        name: "Read",
        description: """
            Reads a file from the local filesystem. You can access any file directly by using this tool.
            Assume this tool is able to read all files on the machine. If the User provides a path to a file assume that path is valid. It is okay to read a file that does not exist; an error will be returned.

            Usage:
            - The file_path parameter must be an absolute path, not a relative path
            - By default, it reads up to 2000 lines starting from the beginning of the file
            - When you already know which part of the file you need, only read that part. This can be important for larger files.
            - Results are returned using cat -n format, with line numbers starting at 1
            - This tool can only read files, not directories. To read a directory, use an ls command via the Bash tool.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object([
                    "type": .string("string"),
                    "description": .string("The absolute path to the file to read"),
                ]),
                "offset": .object([
                    "type": .string("number"),
                    "description": .string(
                        "The line number to start reading from. Only provide if the file is too large to read at once"
                    ),
                ]),
                "limit": .object([
                    "type": .string("number"),
                    "description": .string(
                        "The number of lines to read. Only provide if the file is too large to read at once."
                    ),
                ]),
            ]),
            "required": .array([.string("file_path")]),
            "additionalProperties": .bool(false),
        ])
    )

    // MARK: - Write

    /// Write tool — file creation and overwriting
    public static let write = ToolDefinition(
        name: "Write",
        description: """
            Writes a file to the local filesystem.

            Usage:
            - This tool will overwrite the existing file if there is one at the provided path.
            - If this is an existing file, you MUST use the Read tool first to read the file's contents. This tool will fail if you did not read the file first.
            - Prefer the Edit tool for modifying existing files — it only sends the diff. Only use this tool to create new files or for complete rewrites.
            - NEVER create documentation files (*.md) or README files unless explicitly requested by the User.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The absolute path to the file to write (must be absolute, not relative)"
                    ),
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string("The content to write to the file"),
                ]),
            ]),
            "required": .array([.string("file_path"), .string("content")]),
            "additionalProperties": .bool(false),
        ])
    )

    // MARK: - Edit

    /// Edit tool — exact string replacement in files
    public static let edit = ToolDefinition(
        name: "Edit",
        description: """
            Performs exact string replacements in files.

            Usage:
            - You must use your `Read` tool at least once in the conversation before editing. This tool will error if you attempt an edit without reading the file.
            - When editing text from Read tool output, ensure you preserve the exact indentation (tabs/spaces) as it appears AFTER the line number prefix. The line number prefix format is: line number + tab. Everything after that is the actual file content to match. Never include any part of the line number prefix in the old_string or new_string.
            - ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.
            - The edit will FAIL if `old_string` is not unique in the file. Either provide a larger string with more surrounding context to make it unique or use `replace_all` to change every instance of `old_string`.
            - Use `replace_all` for replacing and renaming strings across the file. This parameter is useful if you want to rename a variable for instance.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object([
                    "type": .string("string"),
                    "description": .string("The absolute path to the file to modify"),
                ]),
                "old_string": .object([
                    "type": .string("string"),
                    "description": .string("The text to replace"),
                ]),
                "new_string": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The text to replace it with (must be different from old_string)"
                    ),
                ]),
                "replace_all": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Replace all occurrences of old_string (default false)"
                    ),
                    "default": .bool(false),
                ]),
            ]),
            "required": .array([
                .string("file_path"),
                .string("old_string"),
                .string("new_string"),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    // MARK: - Bash

    /// Bash tool — shell command execution
    public static let bash = ToolDefinition(
        name: "Bash",
        description: """
            Executes a given bash command and returns its output.

            The working directory persists between commands, but shell state does not. The shell environment is initialized from the user's profile (bash or zsh).

            IMPORTANT: Avoid using this tool to run `find`, `grep`, `cat`, `head`, `tail`, `sed`, `awk`, or `echo` commands, unless explicitly instructed or after you have verified that a dedicated tool cannot accomplish your task. Instead, use the appropriate dedicated tool as this will provide a much better experience for the user.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("The command to execute"),
                ]),
                "timeout": .object([
                    "type": .string("number"),
                    "description": .string(
                        "Optional timeout in milliseconds (max 600000)"
                    ),
                ]),
                "description": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Clear, concise description of what this command does in active voice."
                    ),
                ]),
                "run_in_background": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Set to true to run this command in the background. Use Read to read the output later."
                    ),
                ]),
                "dangerouslyDisableSandbox": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Set this to true to dangerously override sandbox mode and run commands without sandboxing."
                    ),
                ]),
            ]),
            "required": .array([.string("command")]),
            "additionalProperties": .bool(false),
        ])
    )

    // MARK: - Glob

    /// Glob tool — fast file pattern matching
    public static let glob = ToolDefinition(
        name: "Glob",
        description: """
            - Fast file pattern matching tool that works with any codebase size
            - Supports glob patterns like "**/*.js" or "src/**/*.ts"
            - Returns matching file paths sorted by modification time
            - Use this tool when you need to find files by name patterns
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The glob pattern to match files against"
                    ),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The directory to search in. If not specified, the current working directory will be used. IMPORTANT: Omit this field to use the default directory. DO NOT enter \"undefined\" or \"null\" - simply omit it for the default behavior. Must be a valid directory path if provided."
                    ),
                ]),
            ]),
            "required": .array([.string("pattern")]),
            "additionalProperties": .bool(false),
        ])
    )

    // MARK: - Grep

    /// Grep tool — content search powered by ripgrep
    public static let grep = ToolDefinition(
        name: "Grep",
        description: """
            A powerful search tool built on ripgrep

            Usage:
            - ALWAYS use Grep for search tasks. NEVER invoke `grep` or `rg` as a Bash command. The Grep tool has been optimized for correct permissions and access.
            - Supports full regex syntax (e.g., "log.*Error", "function\\s+\\w+")
            - Filter files with glob parameter (e.g., "*.js", "**/*.tsx") or type parameter (e.g., "js", "py", "rust")
            - Output modes: "content" shows matching lines, "files_with_matches" shows only file paths (default), "count" shows match counts
            - Pattern syntax: Uses ripgrep (not grep) - literal braces need escaping
            - Multiline matching: By default patterns match within single lines only. For cross-line patterns, use `multiline: true`
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string(
                        "The regular expression pattern to search for in file contents"
                    ),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string(
                        "File or directory to search in (rg PATH). Defaults to current working directory."
                    ),
                ]),
                "glob": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Glob pattern to filter files (e.g. \"*.js\", \"*.{ts,tsx}\") - maps to rg --glob"
                    ),
                ]),
                "output_mode": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Output mode: \"content\" shows matching lines (supports -A/-B/-C context, -n line numbers, head_limit), \"files_with_matches\" shows file paths (supports head_limit), \"count\" shows match counts (supports head_limit). Defaults to \"files_with_matches\"."
                    ),
                    "enum": .array([
                        .string("content"),
                        .string("files_with_matches"),
                        .string("count"),
                    ]),
                ]),
                "-B": .object([
                    "type": .string("number"),
                    "description": .string(
                        "Number of lines to show before each match (rg -B). Requires output_mode: \"content\", ignored otherwise."
                    ),
                ]),
                "-A": .object([
                    "type": .string("number"),
                    "description": .string(
                        "Number of lines to show after each match (rg -A). Requires output_mode: \"content\", ignored otherwise."
                    ),
                ]),
                "-C": .object([
                    "type": .string("number"),
                    "description": .string("Alias for context."),
                ]),
                "context": .object([
                    "type": .string("number"),
                    "description": .string(
                        "Number of lines to show before and after each match (rg -C). Requires output_mode: \"content\", ignored otherwise."
                    ),
                ]),
                "-n": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Show line numbers in output (rg -n). Requires output_mode: \"content\", ignored otherwise. Defaults to true."
                    ),
                ]),
                "-i": .object([
                    "type": .string("boolean"),
                    "description": .string("Case insensitive search (rg -i)"),
                ]),
                "type": .object([
                    "type": .string("string"),
                    "description": .string(
                        "File type to search (rg --type). Common types: js, py, rust, go, java, etc. More efficient than include for standard file types."
                    ),
                ]),
                "head_limit": .object([
                    "type": .string("number"),
                    "description": .string(
                        "Limit output to first N lines/entries, equivalent to \"| head -N\". Works across all output modes: content (limits output lines), files_with_matches (limits file paths), count (limits count entries). Defaults to 250 when unspecified. Pass 0 for unlimited (use sparingly — large result sets waste context)."
                    ),
                ]),
                "offset": .object([
                    "type": .string("number"),
                    "description": .string(
                        "Skip first N lines/entries before applying head_limit, equivalent to \"| tail -n +N | head -N\". Works across all output modes. Defaults to 0."
                    ),
                ]),
                "multiline": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Enable multiline mode where . matches newlines and patterns can span lines (rg -U --multiline-dotall). Default: false."
                    ),
                ]),
            ]),
            "required": .array([.string("pattern")]),
            "additionalProperties": .bool(false),
        ])
    )

    // MARK: - All Tools

    /// All six tool definitions in registration order.
    public static let all: [ToolDefinition] = [
        read, write, edit, bash, glob, grep,
    ]
}