// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FreeFlow",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.0")
    ],
    targets: [
        .target(
            name: "MarkdownUIBridge",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/PackageSupport"
        )
    ]
)
