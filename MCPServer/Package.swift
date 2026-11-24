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
        // direct モード (MCP サーバー自身が録音・読み上げ) と、両モード共通の時間ログ。
        .target(
            name: "ClaudeTalkCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "claude-talk-mcp-server",
            dependencies: [
                "ClaudeTalkCore",
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "ClaudeTalkCoreTests",
            dependencies: ["ClaudeTalkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
