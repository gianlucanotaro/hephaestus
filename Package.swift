// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hephaestus",
    platforms: [.macOS(.v13)],
    targets: [
        // All app logic lives in the library so tests can `@testable import` it.
        // Foundation-only: CLI protocol, argument parsing, rendering, socket client (shared by the app and the CLI).
        .target(name: "HephaestusIPC", path: "Sources/HephaestusIPC"),
        .target(name: "HephaestusCore", dependencies: ["HephaestusIPC"], path: "Sources/HephaestusCore"),
        .executableTarget(name: "hephaestus-cli", dependencies: ["HephaestusIPC"], path: "Sources/hephaestus-cli"),
        .executableTarget(name: "Hephaestus", dependencies: ["HephaestusCore"], path: "Sources/Hephaestus"),
        .testTarget(name: "HephaestusCoreTests", dependencies: ["HephaestusCore", "HephaestusIPC"], path: "Tests/HephaestusCoreTests"),
        .testTarget(name: "HephaestusIPCTests", dependencies: ["HephaestusIPC"], path: "Tests/HephaestusIPCTests"),
    ]
)
