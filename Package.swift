// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Reclaim",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Reclaim",
            path: "Sources/Reclaim"
        )
    ]
)
