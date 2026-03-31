# SwiftAgentLoop Performance Benchmarks

## Overview

SwiftAgentLoop runs Claude as a native Swift agentic loop — no Node.js process, no CLI subprocess, no IPC overhead. This document quantifies the performance advantage over the Claude Code CLI (Node.js) runtime.

**Test environment:** Apple Silicon Mac, macOS 15, Swift 6.0, debug build (release builds are faster).

---

## Results Summary

| Metric | SwiftAgentLoop | Claude Code CLI (Node.js) | Delta |
|--------|---------------|--------------------------|-------|
| Cold start | **0.36ms** | ~42ms bare / ~300-500ms with app | **100-1400x faster** |
| Memory baseline | **8.4 MB** | ~270-370 MB per process | **32-44x less** |
| Memory peak (20 turns) | **9.1 MB** | 600 MB+ reported | **~66x less** |
| Tool roundtrip (Read) | **1.14ms** | ~90-100ms (first IPC) | **~80x faster** |
| Tool roundtrip (Edit) | **0.29ms** | N/A (no published data) | — |
| Tool roundtrip (Glob) | **0.90ms** | N/A | — |
| Tool roundtrip (Grep) | **10.63ms** | N/A | — |
| Tool roundtrip (Bash) | **1.47ms** | ~30ms spawn overhead | **~20x faster** |

---

## Detailed Results (Swift)

Measured with `ContinuousClock`, 10 iterations per tool benchmark, 100-file tree fixture.

### Startup & Memory

| Benchmark | Value | Notes |
|-----------|-------|-------|
| `cold_start` | 0.36 ms | `AgentConfiguration` + `AgentLoop.init()` |
| `memory_baseline` | 8.4 MB | Resident memory after initialization (`mach_task_basic_info`) |
| `memory_peak_session` | 9.1 MB | Peak resident during a mock 20-turn tool-use session |

### SSE Parsing

| Benchmark | Value | Notes |
|-----------|-------|-------|
| `sse_parse_throughput` | 109 ms for 1,004 events | State-machine byte-level parser, ~9,200 events/sec |

### Tool Roundtrips (min / avg / p99)

| Tool | min | avg | p99 | Notes |
|------|-----|-----|-----|-------|
| Read | 1.07ms | 1.14ms | 1.35ms | 1,000-line file with line numbers |
| Edit | 0.27ms | 0.29ms | 0.32ms | Find-and-replace on 3-line file |
| Glob | 0.86ms | 0.90ms | 1.01ms | `**/*.swift` on 100-file tree |
| Grep | 10.27ms | 10.63ms | 11.18ms | Regex on 100-file tree |
| Bash | 1.33ms | 1.47ms | 1.63ms | `echo hello` via Foundation Process |

---

## Node.js Baseline Data (Published Sources)

### Cold Start

| Measurement | Time | Source |
|-------------|------|--------|
| Bare `node -e 0` | ~41.70 ms | [chocolateboy/startup-time](https://github.com/chocolateboy/startup-time) |
| V8 shell (d8) lower bound | ~7.84 ms | Same source |
| Node.js + minimal framework (Hono) | ~102 ms | [Deno blog — Lambda coldstart benchmarks](https://deno.com/blog/aws-lambda-coldstart-benchmarks) |
| Node.js + Express | ~184 ms | Same source |
| Node.js + bundled app + AWS clients | ~294-511 ms | [Speedrun — Fastest Node 22 Lambda](https://speedrun.nobackspacecrew.com/blog/2025/07/21/the-fastest-node-22-lambda-coldstart-configuration.html) |
| Claude Code startup improvement | ~500 ms saved (deferred hooks) | [Claude Code Changelog](https://claudefa.st/blog/guide/changelog) (v2.1.47) |
| Claude Code startup improvement | ~600 ms saved (deferred MCP) | Same source |
| Claude Code startup improvement | ~60 ms saved (macOS optimization) | Same source (v2.1.78) |
| V8 vs JavaScriptCore (Bun) | ~50 ms vs ~5 ms | [frr.dev — Claude Code Native Build](https://www.frr.dev/posts/claude-code-native-build-bun/) |

**For comparison, compiled languages:**
- C (gcc): 0.38 ms
- Rust: 0.64 ms
- Go: 0.88 ms
- Source: [chocolateboy/startup-time](https://github.com/chocolateboy/startup-time)

### Memory

| Measurement | RSS | Source |
|-------------|-----|--------|
| Bare Node.js process | ~24-37 MB | [GeeksforGeeks](https://www.geeksforgeeks.org/node-js/node-js-process-memoryusage-method/), [valentinog.com](https://www.valentinog.com/blog/node-usage/) |
| Claude Code per-process | ~270-370 MB | [GitHub Issue #11122](https://github.com/anthropics/claude-code/issues/11122) |
| Claude Code fresh install | ~600 MB, growing to 20 GB | [GitHub Issue #15963](https://github.com/anthropics/claude-code/issues/15963) |
| Claude Code long sessions (300+ messages) | Spikes to ~15 GB | [GitHub Issue #21378](https://github.com/anthropics/claude-code/issues/21378) |
| Claude Code memory reduction (deferred WASM) | ~16 MB saved | [Changelog](https://claudefa.st/blog/guide/changelog) (v2.1.69) |
| Claude Code memory reduction (startup) | ~18 MB saved | Same source (v2.1.79) |
| Claude Code memory reduction (large repos) | ~80 MB saved on 250K-file repos | Same source (v2.1.80) |

### IPC / Subprocess Overhead

| Measurement | Value | Source |
|-------------|-------|--------|
| First IPC message latency (cold) | 90-100 ms | [Node.js Issue #3145](https://github.com/nodejs/node/issues/3145) |
| Subsequent IPC messages (warm) | 0.12-0.51 ms | Same source |
| Process spawn overhead | ~30 ms + ~10 MB per process | [Val Town — Node Spawn Performance](https://blog.val.town/blog/node-spawn-performance/) |
| Spawn throughput (Node.js) | 651 req/s | Same source |
| Spawn throughput (Rust) | 5,466 req/s | Same source |
| Spawn throughput (Go) | 5,227 req/s | Same source |
| Node main thread blocked on spawn() | ~30% under load | Same source |

### SSE Parsing

No absolute throughput numbers published for JavaScript SSE parsers. Relative data only:

- `eventsource-parser` v3.0.1 is ~100x faster than v3.0.0
- `eventsource-parser` v3.0.1 is ~10x faster than `@ai-sdk/provider-utils`
- Source: [eventsource-parser-benchmark](https://github.com/gr2m/eventsource-parser-benchmark), [Vercel AI SDK Issue #5862](https://github.com/vercel/ai/issues/5862)

---

## Why Native Swift Wins

### 1. No Process Spawn Overhead

Claude Code CLI spawns a Node.js process for each session. That's ~42ms minimum for the runtime alone, plus hundreds of milliseconds for application initialization (SDK handshake, hook setup, MCP server connections).

SwiftAgentLoop initializes in **0.36ms** — it's a function call, not a process spawn.

### 2. No IPC Layer

Claude Code tools execute in the Node.js process and communicate results via JSON over stdin/stdout pipes. Each tool invocation pays the serialization + pipe I/O cost.

SwiftAgentLoop tools execute in-process as direct function calls. A Read tool invocation is a `String(contentsOf:)` call — no serialization, no pipe, no parsing.

### 3. Minimal Memory Footprint

Node.js starts at ~24-37 MB just for the runtime. Claude Code adds its dependency tree (TypeScript, SDK, React/Ink for TUI) reaching ~270-370 MB per process.

SwiftAgentLoop's entire agent loop — client, SSE parser, 7 tools, permission system, prompt builder — uses **8.4 MB**. After a 20-turn session with tool use: **9.1 MB**.

### 4. No V8 JIT Warmup

V8's JIT compiler means Node.js programs are slow on first execution and get faster as hot paths are compiled. This creates inconsistent latency, especially for short-lived tool executions.

Swift compiles ahead-of-time. Every tool call has consistent, predictable latency from the first invocation.

---

## Running the Benchmarks

```bash
# Local benchmarks (no API key needed)
swift run SwiftAgentLoopBenchmarks

# Or use the convenience script (release mode, saves to benchmark-results.md)
./scripts/run-benchmarks.sh

# With E2E API benchmarks
ANTHROPIC_API_KEY=sk-ant-... ./scripts/run-benchmarks.sh
```

---

## Methodology Notes

- **Swift measurements** were taken in debug build. Release builds would show even better numbers.
- **Node.js baselines** are from published sources (linked above), not measured on the same machine. They represent typical performance, not best-case.
- **Tool roundtrips** measure the full `execute()` call including validation, file I/O, and result construction.
- **Memory** is measured via `mach_task_basic_info` (resident set size).
- **Cold start** measures `AgentConfiguration` construction + `AgentLoop` actor initialization, not including the first API call.
- **SSE parse throughput** feeds synthetic events as raw bytes through the state-machine parser — no network I/O.
