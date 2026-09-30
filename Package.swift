// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mug",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Mug", path: "Sources/Mug")
    ]
)
