// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Vimotion",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk.git",
            exact: "0.12.1"
        )
    ],
    targets: [
        .executableTarget(
            name: "Vimotion",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/Vimotion"
        ),
        .testTarget(
            name: "VimotionTests",
            dependencies: [
                "Vimotion"
            ],
            path: "Tests/VimotionTests"
        )
    ]
)
