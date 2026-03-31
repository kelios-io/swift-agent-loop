#!/bin/bash
set -euo pipefail

echo "Building benchmarks..."
swift build -c release --product SwiftAgentLoopBenchmarks 2>/dev/null

echo "Running benchmarks (release mode)..."
swift run -c release SwiftAgentLoopBenchmarks
