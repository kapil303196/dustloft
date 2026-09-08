// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Attic",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Attic",
            path: "Sources/Attic"
        ),
        .testTarget(
            name: "AtticTests",
            dependencies: ["Attic"],
            path: "Tests/AtticTests"
        )
    ]
)
