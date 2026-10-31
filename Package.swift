// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ModEdit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "LanguageExperimentProtocol",
            targets: ["LanguageExperimentProtocol"]),
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
    dependencies: [
        .package(url: "https://github.com/hakkabon/Grammar.git", .upToNextMinor(from: "0.3.0")),
        .package(url: "https://github.com/hakkabon/Parser.git", .upToNextMinor(from: "0.3.0")),
        .package(url: "https://github.com/hakkabon/Lexer.git", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/hakkabon/Earley-Parser.git", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/hakkabon/CYK-Parser.git", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/hakkabon/RNGLR-Parser.git", .upToNextMinor(from: "0.2.1")),
        .package(url: "https://github.com/hakkabon/LR-Parsing.git", .upToNextMinor(from: "0.2.3")),
        .package(url: "https://github.com/hakkabon/LL-Parsing.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/hakkabon/Earley-TableParser.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/hakkabon/GrammarDiagram.git", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/hakkabon/Compiler.git", .upToNextMinor(from: "0.3.0")),
    ],
    targets: [
        .target(
            name: "LanguageExperimentProtocol"),
        .target(
            name: "CompilerBridge",
            dependencies: [
                .product(name: "Compiler", package: "Compiler"),
            ]),
        .target(
            name: "PL0Language",
            dependencies: [
                "LanguageExperimentProtocol",
                "CompilerBridge",
                .product(name: "Grammar", package: "Grammar"),
                .product(name: "Parser", package: "Parser"),
                .product(name: "Lexer", package: "Lexer"),
                .product(name: "Earley-Parser", package: "Earley-Parser"),
                .product(name: "CYK-Parser", package: "CYK-Parser"),
                .product(name: "RNGLR-Parser", package: "RNGLR-Parser"),
                .product(name: "LR-Parsing", package: "LR-Parsing"),
                .product(name: "LL-Parsing", package: "LL-Parsing"),
                .product(name: "Earley-TableParser", package: "Earley-TableParser"),
                .product(name: "GrammarDiagram", package: "GrammarDiagram"),
            ],
            resources: [.process("Resources")]),
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
        .testTarget(
            name: "LanguageExperimentProtocolTests",
            dependencies: ["LanguageExperimentProtocol"]),
    ]
)
