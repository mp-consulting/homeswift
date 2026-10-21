// swift-tools-version:6.1

import PackageDescription

let package = Package(
    name: "homeswift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Homeswift", targets: ["Homeswift"]),
        .library(name: "HomeswiftPlugin", targets: ["HomeswiftPlugin"]),
        .library(name: "HomeswiftAI", targets: ["HomeswiftAI"]),
        .library(name: "HomeswiftMCP", targets: ["HomeswiftMCP"]),
        .library(name: "HomeswiftElgatoKeyLights", targets: ["HomeswiftElgatoKeyLights"]),
        .executable(name: "homeswift", targets: ["HomeswiftCLI"]),
        .executable(name: "homeswift-demo", targets: ["homeswift-demo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.11.0"),
    ],
    targets: [
        // Bonjour on Linux goes through Avahi's dns_sd compatibility layer; macOS has dns_sd built in.
        // No pkgConfig: SwiftPM looks it up on every platform and warns on macOS. shim.h finds the header.
        .systemLibrary(name: "CDNSSD", providers: [.apt(["libavahi-compat-libdnssd-dev"])]),
        // Montgomery multiplication for SRP; C keeps it fast even in debug builds.
        .target(name: "CHAPMath"),
        .target(
            name: "Homeswift",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                "CHAPMath",
                .target(name: "CDNSSD", condition: .when(platforms: [.linux])),
            ]
        ),
        // The Assistant: chat providers over plain HTTP (Claude, OpenAI, Gemini, OpenAI-compatible) and Apple's
        // on-device model, redaction, prompts, schema-checked JSON. No dependency beyond Foundation and swift-log.
        .target(
            name: "HomeswiftAI",
            dependencies: [.product(name: "Logging", package: "swift-log")]
        ),
        // The plugin API and the runtime that hosts plugins: config.json, cached accessories, child bridges.
        .target(
            name: "HomeswiftPlugin",
            dependencies: [
                "Homeswift", "HomeswiftAI",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // The MCP server: Streamable HTTP inside the bridge, tools over its accessories, plugins, config and logs,
        // scopes, confirmations and an audit log; `homeswift mcp` proxies stdio to it.
        .target(
            name: "HomeswiftMCP",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftAI",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // Plugins live under Plugins/<Name>/ with their own Sources and Tests, the layout of a standalone
        // package, so moving one into its own repository is a directory move plus a Package.swift.
        .target(
            name: "HomeswiftElgatoKeyLights",
            dependencies: ["Homeswift", "HomeswiftPlugin", .product(name: "Logging", package: "swift-log")],
            path: "Plugins/ElgatoKeyLights/Sources"
        ),
        // The `homeswift` bridge: reads config.json and runs the plugins compiled in (Plugins.swift lists them).
        // The target is not named "homeswift": that is "Homeswift" on a case-insensitive file system.
        .executableTarget(
            name: "HomeswiftCLI",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftAI", "HomeswiftMCP", "HomeswiftElgatoKeyLights",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(name: "homeswift-demo", dependencies: ["Homeswift"]),
        .testTarget(
            name: "HomeswiftTests",
            dependencies: ["Homeswift", .product(name: "Logging", package: "swift-log")]
        ),
        .testTarget(
            name: "HomeswiftAITests",
            dependencies: ["HomeswiftAI", .product(name: "Logging", package: "swift-log")]
        ),
        .testTarget(
            name: "HomeswiftMCPTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftAI", "HomeswiftMCP",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "HomeswiftPluginTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "ElgatoKeyLightsTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftElgatoKeyLights",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/ElgatoKeyLights/Tests"
        ),
    ]
)
