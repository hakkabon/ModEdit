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
        .package(url: "https://github.com/hakkabon/PL0-LanguageKit.git", .upToNextMinor(from: "0.16.2")),
        .package(url: "https://github.com/hakkabon/Incremental-Parsing.git", .upToNextMinor(from: "0.33.0")),
        .package(url: "https://github.com/hakkabon/Language-Tooling.git", .upToNextMinor(from: "0.10.1")),
        .package(url: "https://github.com/hakkabon/ModEdit-Bundled-Languages.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/hakkabon/JSON-LanguageKit.git", .upToNextMinor(from: "0.2.1")),
        .package(url: "https://github.com/hakkabon/Grammar-LanguageKit.git", .upToNextMinor(from: "0.2.1")),
        .package(url: "https://github.com/hakkabon/Grammar.git", .upToNextMinor(from: "0.9.1")),
        .package(url: "https://github.com/hakkabon/Railroad.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/hakkabon/DOT-LanguageKit.git", .upToNextMinor(from: "0.2.1")),
        .package(url: "https://github.com/hakkabon/CSS-LanguageKit.git", .upToNextMinor(from: "0.2.1")),
        .package(url: "https://github.com/hakkabon/Swift-Layout.git", .upToNextMinor(from: "0.0.3")),
    ],
    targets: [
        .target(
            name: "ModEditCore",
            dependencies: [
                .product(name: "PL0Language", package: "PL0-LanguageKit"),
                .product(name: "PL0FrontendConformance", package: "PL0-LanguageKit"),
                .product(name: "IncrementalParsing", package: "Incremental-Parsing"),
                .product(name: "LanguageTooling", package: "Language-Tooling"),
                .product(
                    name: "ModEditBundledLanguages",
                    package: "ModEdit-Bundled-Languages"),
                .product(name: "JSONLanguage", package: "JSON-LanguageKit"),
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "Railroad", package: "Railroad"),
                .product(
                    name: "GrammarLanguage",
                    package: "Grammar-LanguageKit"),
                .product(name: "DOTLanguage", package: "DOT-LanguageKit"),
                .product(name: "SwiftLayout", package: "Swift-Layout"),
                .product(name: "CSSLanguage", package: "CSS-LanguageKit"),
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
                .product(name: "LanguageTooling", package: "Language-Tooling"),
            ]),
    ]
)
