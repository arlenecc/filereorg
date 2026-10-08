// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FileReorg",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FileReorg",
            path: "Sources/FileReorg"
        ),
        .testTarget(
            name: "FileReorgTests",
            dependencies: ["FileReorg"],
            path: "Tests/FileReorgTests"
        )
    ]
)
