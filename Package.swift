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
        .executable(name: "modedit-experiment", targets: ["ModEditExperimentCLI"]),
    ],
    dependencies: [
        .package(path: "../PL0-LanguageKit"),
        .package(path: "../Incremental-Parsing"),
    ],
    targets: [
        .target(
            name: "ModEditCore",
            dependencies: [
                .product(name: "PL0Language", package: "PL0-LanguageKit"),
                .product(name: "PL0FrontendConformance", package: "PL0-LanguageKit"),
                .product(name: "IncrementalParsing", package: "Incremental-Parsing"),
            ]),
        .executableTarget(
            name: "ModEditApp",
            dependencies: ["ModEditCore"],
            // Info.plist is consumed by scripts/make-app.sh when assembling the
            // .app bundle; SwiftPM must not treat it as a target resource.
            exclude: ["Resources/Info.plist"]),
        .executableTarget(
            name: "ModEditExperimentCLI",
            dependencies: [
                "ModEditCore",
                .product(name: "PL0FrontendConformance", package: "PL0-LanguageKit"),
                .product(name: "IncrementalParsing", package: "Incremental-Parsing"),
            ]),
        .testTarget(
            name: "ModEditTests",
            dependencies: [
                "ModEditCore",
                .product(name: "IncrementalParsing", package: "Incremental-Parsing"),
            ]),
    ]
)
