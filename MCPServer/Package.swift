// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MCPServer",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "claude-talk-mcp-server",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ]
        )
    ]
)
