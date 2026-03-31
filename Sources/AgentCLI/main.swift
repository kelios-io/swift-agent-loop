import Foundation
import SwiftAgentLoop

// 1. Get API key from environment
guard let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
    print("Error: ANTHROPIC_API_KEY environment variable not set")
    exit(1)
}

// 2. Read prompt from command line args or stdin
let prompt: String
if CommandLine.arguments.count > 1 {
    prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
} else {
    print("Enter prompt (Ctrl-D to submit):")
    var lines: [String] = []
    while let line = readLine() {
        lines.append(line)
    }
    prompt = lines.joined(separator: "\n")
}

guard !prompt.isEmpty else {
    print("Error: No prompt provided")
    exit(1)
}

// 3. Create transport with all default tools
let transport = NativeTransport.withDefaultTools(
    apiKey: apiKey,
    model: ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"] ?? "claude-sonnet-4-6",
    permissionCallback: { toolName, input in
        // Auto-approve read-only tools
        if ["Read", "Glob", "Grep"].contains(toolName) {
            return .approve
        }

        // Check for destructive commands
        if toolName == "Bash", let command = input["command"] as? String,
           let warning = DestructiveDetector.check(command: command) {
            print("\n\u{26a0}\u{fe0f}  Destructive command detected: \(warning)")
            print("Command: \(command)")
            print("Allow? [y/N] ", terminator: "")
            fflush(stdout)
            if let response = readLine(), response.lowercased() == "y" {
                return .approve
            }
            return .block(reason: "User denied destructive command")
        }

        // Prompt for non-read tools
        print("\nTool: \(toolName)")
        print("Input: \(input)")
        print("Allow? [Y/n] ", terminator: "")
        fflush(stdout)
        if let response = readLine(), response.lowercased() == "n" {
            return .block(reason: "User denied")
        }
        return .approve
    }
)

// 4. Run the agentic loop
let workingDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
print("\n--- Running agent ---\n")

let stream = await transport.start(
    prompt: prompt,
    systemPrompt: nil,
    workingDirectory: workingDir
)

for await event in stream {
    switch event {
    case .textDelta(let text):
        print(text, terminator: "")
        fflush(stdout)
    case .thinkingDelta(let text):
        print("[thinking] \(text)", terminator: "")
    case .toolUseStart(let id, let name):
        print("\n\n--- Tool: \(name) (id: \(id)) ---")
    case .toolUseInput(_, let json):
        print(json, terminator: "")
    case .toolResult(let id, let output, let isError):
        let prefix = isError ? "ERROR" : "OK"
        let truncated = output.count > 500 ? String(output.prefix(500)) + "..." : output
        print("\n[\(prefix)] Result (\(id)): \(truncated)")
    case .usage(let input, let output, let cacheRead, let cacheCreation):
        print("\n[tokens: in=\(input) out=\(output)" +
              (cacheRead.map { " cache_read=\($0)" } ?? "") +
              (cacheCreation.map { " cache_create=\($0)" } ?? "") + "]")
    case .turnComplete(let turn):
        print("\n--- Turn \(turn) complete ---\n")
    case .done(let reason):
        print("\n\n--- Done: \(reason) ---")
    case .error(let error):
        print("\n\nError: \(error)")
    }
}

print() // Final newline