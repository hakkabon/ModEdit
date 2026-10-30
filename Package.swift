// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ModEdit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PL0Language",
            targets: ["PL0Language"]),
        .library(
            name: "ModEditCore",
            targets: ["ModEditCore"]),
        .executable(
            name: "ModEdit",
            targets: ["ModEditApp"]),
    ],
    targets: [
        .target(
            name: "PL0Language"),
        .target(
            name: "ModEditCore",
            dependencies: ["PL0Language"]),
        .executableTarget(
            name: "ModEditApp",
            dependencies: ["ModEditCore"],
            // Info.plist is consumed by scripts/make-app.sh when assembling the
            // .app bundle; SwiftPM must not treat it as a target resource.
            exclude: ["Resources/Info.plist"]),
        .testTarget(
            name: "ModEditTests",
            dependencies: ["ModEditCore"]),
        .testTarget(
            name: "PL0LanguageTests",
            dependencies: ["PL0Language"]),
    ]
)
