// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FreeFlowNotesMCP",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "freeflow-notes-mcp", targets: ["FreeFlowNotesMCP"])],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .target(name: "FreeFlowNotesCore"),
        .executableTarget(name: "FreeFlowNotesMCP", dependencies: ["FreeFlowNotesCore", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "FreeFlowNotesMCPTests", dependencies: ["FreeFlowNotesCore"])
    ]
)
