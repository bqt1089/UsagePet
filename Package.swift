// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageWidget",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ClaudeUsageCore", targets: ["ClaudeUsageCore"]),
        .executable(name: "ClaudeUsageWidget", targets: ["ClaudeUsageWidget"])
    ],
    targets: [
        .target(
            name: "ClaudeUsageCore",
            path: "Sources/ClaudeUsageCore"
        ),
        .executableTarget(
            name: "ClaudeUsageWidget",
            dependencies: ["ClaudeUsageCore"],
            path: "Sources/ClaudeUsageWidget",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "ClaudeUsageCoreTests",
            dependencies: ["ClaudeUsageCore"],
            path: "Tests/ClaudeUsageCoreTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
