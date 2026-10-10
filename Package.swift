// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "waid",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "waid", targets: ["waid"]),
        .library(name: "WaidCore", targets: ["WaidCore"]),
        .library(name: "WaidMCP", targets: ["WaidMCP"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]
        ),
        .target(name: "WaidCore", dependencies: ["CSQLite"]),
        .target(name: "WaidMCP", dependencies: ["WaidCore"]),
        // macOS-only capture backends; compiles to an empty module elsewhere.
        .target(name: "WaidCapture", dependencies: ["WaidCore"]),
        .executableTarget(name: "waid", dependencies: ["WaidCore", "WaidMCP", "WaidCapture"]),
        .testTarget(name: "WaidCoreTests", dependencies: ["WaidCore"]),
        .testTarget(name: "WaidMCPTests", dependencies: ["WaidMCP", "WaidCore"]),
    ],
    swiftLanguageModes: [.v5]
)
