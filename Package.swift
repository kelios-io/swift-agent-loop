// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftAgentLoop",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "SwiftAgentLoop", targets: ["SwiftAgentLoop"]),
        .executable(name: "AgentCLI", targets: ["AgentCLI"]),
    ],
    targets: [
        .target(
            name: "SwiftAgentLoop",
            path: "Sources/SwiftAgentLoop"
        ),
        .executableTarget(
            name: "AgentCLI",
            dependencies: ["SwiftAgentLoop"],
            path: "Sources/AgentCLI"
        ),
        .executableTarget(
            name: "SwiftAgentLoopBenchmarks",
            dependencies: ["SwiftAgentLoop"],
            path: "Sources/Benchmarks"
        ),
        .testTarget(
            name: "SwiftAgentLoopTests",
            dependencies: ["SwiftAgentLoop"],
            path: "Tests/SwiftAgentLoopTests"
        ),
    ]
)
