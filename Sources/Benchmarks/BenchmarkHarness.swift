import Foundation

/// Result of a single benchmark run.
struct BenchmarkResult: Sendable {
    let name: String
    let value: String
    let unit: String
}

/// Simple benchmark harness using ContinuousClock.
enum BenchmarkHarness {
    nonisolated(unsafe) private(set) static var results: [BenchmarkResult] = []

    /// Measure an async block over N iterations. Reports min/avg/p99.
    static func measure(
        name: String,
        iterations: Int = 100,
        warmup: Int = 5,
        unit: String = "ms",
        block: () async throws -> Void
    ) async rethrows {
        for _ in 0..<warmup {
            try await block()
        }

        var durations: [Double] = []
        let clock = ContinuousClock()

        for _ in 0..<iterations {
            let elapsed = try await clock.measure {
                try await block()
            }
            let ms = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000 +
                     Double(elapsed.components.seconds) * 1000
            durations.append(ms)
        }

        durations.sort()
        let min = durations.first ?? 0
        let avg = durations.reduce(0, +) / Double(durations.count)
        let p99Index = Int(Double(durations.count) * 0.99)
        let p99 = durations[Swift.min(p99Index, durations.count - 1)]

        let value = String(format: "%.2f / %.2f / %.2f", min, avg, p99)
        results.append(BenchmarkResult(name: name, value: value, unit: "ms (min/avg/p99)"))
        print("  \(name): \(value) \(unit) (min/avg/p99)")
    }

    /// Measure a single-shot operation.
    static func measureOnce(
        name: String,
        unit: String = "ms",
        block: () async throws -> Void
    ) async rethrows {
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            try await block()
        }
        let ms = Double(elapsed.components.attoseconds) / 1_000_000_000_000_000 +
                 Double(elapsed.components.seconds) * 1000
        let value = String(format: "%.2f", ms)
        results.append(BenchmarkResult(name: name, value: value, unit: unit))
        print("  \(name): \(value) \(unit)")
    }

    /// Record a pre-computed value.
    static func record(name: String, value: String, unit: String) {
        results.append(BenchmarkResult(name: name, value: value, unit: unit))
        print("  \(name): \(value) \(unit)")
    }

    /// Print all results as a markdown table.
    static func printMarkdownTable() {
        print("\n## Benchmark Results\n")
        print("| Benchmark | Value | Unit |")
        print("|-----------|-------|------|")
        for r in results {
            print("| \(r.name) | \(r.value) | \(r.unit) |")
        }
    }
}
