// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ModEdit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "ModEditCore",
            targets: ["ModEditCore"]),
        .executable(
            name: "ModEdit",
            targets: ["ModEditApp"]),
    ],
    targets: [
        .target(
            name: "ModEditCore"),
        .executableTarget(
            name: "ModEditApp",
            dependencies: ["ModEditCore"]),
        .testTarget(
            name: "ModEditTests",
            dependencies: ["ModEditCore"]),
    ]
)
