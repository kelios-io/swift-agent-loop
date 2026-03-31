#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_FILE="${PROJECT_DIR}/benchmark-results.md"

cd "$PROJECT_DIR"

echo "=== SwiftAgentLoop Benchmark Suite ==="
echo ""

# Build in release mode for accurate numbers
echo "Building (release mode)..."
swift build -c release --product SwiftAgentLoopBenchmarks 2>&1 | tail -1

echo "Running benchmarks..."
echo ""

# Run and tee to both stdout and file
swift run -c release --skip-build SwiftAgentLoopBenchmarks 2>&1 | tee "$OUTPUT_FILE"

echo ""
echo "Results saved to: $OUTPUT_FILE"
