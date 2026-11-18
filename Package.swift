// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hephaestus",
    platforms: [.macOS(.v13)],
    targets: [
        // All app logic lives in the library so tests can `@testable import` it.
        .target(name: "HephaestusCore", path: "Sources/HephaestusCore"),
        .executableTarget(name: "Hephaestus", dependencies: ["HephaestusCore"], path: "Sources/Hephaestus"),
        .testTarget(name: "HephaestusCoreTests", dependencies: ["HephaestusCore"], path: "Tests/HephaestusCoreTests"),
    ]
)
