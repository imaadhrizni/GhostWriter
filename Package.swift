// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GhostWriter",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "GhostWriter",
            path: "Sources"
        ),
        .testTarget(
            name: "GhostWriterTests",
            dependencies: ["GhostWriter"],
            path: "Tests/GhostWriterTests"
        )
    ]
)
