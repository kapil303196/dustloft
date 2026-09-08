// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dustloft",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Dustloft",
            path: "Sources/Dustloft"
        ),
        .testTarget(
            name: "DustloftTests",
            dependencies: ["Dustloft"],
            path: "Tests/DustloftTests"
        )
    ]
)
