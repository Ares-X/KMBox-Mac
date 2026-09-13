// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KMBoxMac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KMBoxCore", targets: ["KMBoxCore"]),
        .executable(name: "KMBoxMac", targets: ["KMBoxApp"]),
        .executable(name: "kmctl", targets: ["kmctl"])
    ],
    targets: [
        .target(name: "KMBoxCore"),
        .executableTarget(name: "KMBoxApp", dependencies: ["KMBoxCore"]),
        .executableTarget(name: "kmctl", dependencies: ["KMBoxCore"]),
        .testTarget(name: "KMBoxCoreTests", dependencies: ["KMBoxCore", "KMBoxApp"])
    ]
)
