// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hephaestus",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Hephaestus", path: "Sources/Hephaestus")
    ]
)
