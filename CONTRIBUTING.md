# Contributing to SwiftAgentLoop

Thank you for your interest in contributing! This guide will help you get started.

## Getting Started

1. Fork and clone the repository
2. Ensure you have Swift 6.0+ and macOS 15+ installed
3. Run `swift build` to verify the project compiles
4. Run `swift test` to verify all tests pass

## Development

### Project Structure

```
Sources/
├── SwiftAgentLoop/     # Core library
│   ├── Client/         # HTTP client, SSE parser, API types
│   ├── Engine/         # Agent loop, state, transport
│   ├── Tools/          # Built-in tool implementations
│   ├── Permissions/    # Permission system, destructive detection
│   └── Prompt/         # System prompt builder, tool schemas
└── AgentCLI/           # CLI test harness
Tests/
└── SwiftAgentLoopTests/
```

### Code Style

- Follow existing patterns in the codebase
- Use Swift Testing framework (`@Suite`, `@Test`, `#expect`) for new tests
- All public types need doc comments
- Zero external dependencies — Foundation only
- Swift 6 strict concurrency: all types crossing isolation boundaries must be `Sendable`

### Running Tests

```bash
# All tests
swift test

# Specific suite
swift test --filter BashTool

# Integration tests (requires API key)
ANTHROPIC_API_KEY=sk-ant-... swift test --filter Integration
```

## Pull Requests

1. Create a feature branch from `main`
2. Keep changes focused — one feature or fix per PR
3. Add tests for new functionality
4. Ensure `swift build` and `swift test` pass
5. Write a clear PR description explaining what and why

## Reporting Issues

Open an issue on GitHub with:
- What you expected to happen
- What actually happened
- Steps to reproduce
- Swift version and macOS version

## License

By contributing, you agree that your contributions will be licensed under the Apache 2.0 License.
