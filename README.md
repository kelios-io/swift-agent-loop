# SwiftAgentLoop

A native Swift agentic loop for the Anthropic Messages API. Run Claude as a coding agent in macOS/iOS/visionOS apps — no Node.js, no CLI subprocess, no third-party runtime.

## Features

- **Streaming SSE client** — state-machine parser handles arbitrary chunk boundaries
- **Agentic state machine** — prompt > API > tool-use > tool-result cycle with parallel tool dispatch
- **6 built-in tools** — Read, Write, Edit, Bash, Glob, Grep (schemas match Claude Code)
- **Permission system** — async callback before tool execution, session-level approvals
- **Destructive command detection** — flags `rm -rf`, `git push --force`, `dd`, `curl|sh`, etc.
- **Configurable system prompt** — environment-aware prompt builder
- **Zero dependencies** — Foundation only, no external packages

## Benchmarks

| Metric | SwiftAgentLoop | Claude Code CLI (Node.js) | Delta |
|--------|---------------|--------------------------|-------|
| Cold start | **0.36 ms** | ~300-500 ms | **~1000x faster** |
| Memory baseline | **8.4 MB** | ~270-370 MB | **~40x less** |
| Memory (20-turn session) | **9.1 MB** | 600 MB+ reported | **~66x less** |
| Tool roundtrip (Read) | **1.14 ms** | ~90-100 ms (IPC) | **~80x faster** |
| Tool roundtrip (Bash) | **1.47 ms** | ~30 ms (spawn) | **~20x faster** |
| SSE parse (1K events) | **109 ms** | No published data | — |

See [docs/benchmarks.md](docs/benchmarks.md) for full methodology and sources.

## Requirements

- macOS 15+
- Swift 6.0+

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/kelios-io/swift-agent-loop.git", from: "0.1.0"),
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "SwiftAgentLoop", package: "swift-agent-loop"),
    ]
),
```

## Quick Start

```swift
import SwiftAgentLoop

let transport = NativeTransport.withDefaultTools(
    apiKey: "sk-ant-...",
    model: "claude-sonnet-4-6",
    permissionCallback: { toolName, input in
        // Auto-approve read-only tools
        if ["Read", "Glob", "Grep"].contains(toolName) {
            return .approve
        }
        return .approve // or .block(reason:) or .approveForSession
    }
)

let workingDir = URL(fileURLWithPath: "/path/to/project")
let stream = await transport.start(
    prompt: "Read main.swift and explain what it does",
    systemPrompt: nil,
    workingDirectory: workingDir
)

for await event in stream {
    switch event {
    case .textDelta(let text):
        print(text, terminator: "")
    case .toolUseStart(_, let name):
        print("\n[Tool: \(name)]")
    case .toolResult(_, let output, _):
        print("[Result: \(output.prefix(100))...]")
    case .done(let reason):
        print("\nDone: \(reason)")
    case .error(let error):
        print("\nError: \(error)")
    default:
        break
    }
}
```

## Authentication

The library supports two authentication modes via `AuthCredential`:

- **`.apiKey(String)`** — API key from [console.anthropic.com](https://console.anthropic.com). Recommended for all third-party apps.
- **`.oauth(OAuthTokenManager)`** — OAuth bearer tokens with automatic refresh. For Teams/Enterprise accounts or Anthropic-authorized applications only.

> **Note:** Anthropic's Consumer ToS restricts OAuth tokens from Claude Pro/Max subscriptions to official Anthropic applications. Third-party apps should use API keys.

## Architecture

```
SwiftAgentLoop/
├── Client/
│   ├── AnthropicClient.swift      — Streaming HTTP client, retry with jitter
│   ├── MessageTypes.swift         — Full Codable API surface (Messages API)
│   └── SSEParser.swift            — State-machine SSE parser
├── Engine/
│   ├── AgentLoop.swift            — Agentic state machine, parallel tool dispatch
│   ├── AgentEvent.swift           — Stream events
│   ├── AgentState.swift           — Loop state tracking
│   ├── AgentTransport.swift       — Protocol + NativeTransport
│   └── ContextManager.swift       — Context window management (E2)
├── Tools/
│   ├── AgentTool.swift            — Protocol, ToolResult, ToolContext
│   ├── BashTool.swift             — Foundation Process with timeout
│   ├── ReadTool.swift             — File reading with line numbers
│   ├── WriteTool.swift            — File creation/overwrite
│   ├── EditTool.swift             — String replacement
│   ├── GlobTool.swift             — Recursive file matching
│   └── GrepTool.swift             — Regex search
├── Permissions/
│   ├── PermissionCallback.swift   — Async callback types
│   └── DestructiveDetector.swift  — Command safety classification
└── Prompt/
    ├── SystemPromptBuilder.swift  — Configurable system prompt
    └── PromptToolSchemas.swift    — Tool JSON schemas
```

## CLI

A test harness is included for standalone validation:

```bash
ANTHROPIC_API_KEY=sk-ant-... swift run AgentCLI "List the files in this directory"
```

## Built for Fermata

SwiftAgentLoop powers [Fermata](https://fermata.run) — a native macOS agent orchestrator for directing Claude sessions visually.

## License

Apache 2.0 — see [LICENSE](LICENSE).
