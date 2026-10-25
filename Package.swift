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
        .library(name: "HomeswiftUI", targets: ["HomeswiftUI"]),
        .library(name: "HomeswiftNetwork", targets: ["HomeswiftNetwork"]),
        .library(name: "HomeswiftFFmpeg", targets: ["HomeswiftFFmpeg"]),
        .library(name: "HomeswiftElgatoKeyLights", targets: ["HomeswiftElgatoKeyLights"]),
        .library(name: "HomeswiftPhilipsAmbilightTV", targets: ["HomeswiftPhilipsAmbilightTV"]),
        .library(name: "HomeswiftDolphinPoolCleaner", targets: ["HomeswiftDolphinPoolCleaner"]),
        .library(name: "HomeswiftDysonPureCool", targets: ["HomeswiftDysonPureCool"]),
        .library(name: "HomeswiftUniFiAccess", targets: ["HomeswiftUniFiAccess"]),
        .library(name: "HomeswiftDaikinCloud", targets: ["HomeswiftDaikinCloud"]),
        .library(name: "HomeswiftEWeLink", targets: ["HomeswiftEWeLink"]),
        .library(name: "HomeswiftLGThinQ", targets: ["HomeswiftLGThinQ"]),
        .library(name: "HomeswiftGovee", targets: ["HomeswiftGovee"]),
        .library(name: "HomeswiftUniFiProtect", targets: ["HomeswiftUniFiProtect"]),
        .library(name: "HomeswiftWingman", targets: ["HomeswiftWingman"]),
        .executable(name: "homeswift", targets: ["HomeswiftCLI"]),
        .executable(name: "homeswift-demo", targets: ["homeswift-demo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.11.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
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
                "Homeswift", "HomeswiftPlugin", "HomeswiftAI", "HomeswiftNetwork",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // The web UI: a NIO HTTP server inside the bridge with a form login, pages for status, accessories, plugin
        // settings (forms from each plugin's config.schema.json), config.json and the log. Web/ is embedded into
        // WebAssets.swift by Scripts/embed-assets.swift.
        .target(
            name: "HomeswiftUI",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftAI", "HomeswiftMCP", "HomeswiftNetwork",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ],
            exclude: ["Web"]
        ),
        // What plugins need to reach devices and clouds: an HTTP client that can trust a self-signed certificate and
        // pin it, HTTP Digest authentication, Wake-on-LAN, a WebSocket client, an MQTT 3.1.1 client (TCP, TLS with a
        // client certificate, WebSocket) and AWS Signature Version 4. On NIO and NIOSSL so it works the same on Linux, where
        // URLSession cannot accept a certificate the system does not trust.
        .target(
            name: "HomeswiftNetwork",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // FFmpeg for camera plugins (a port of homebridge-plugin-utils' ffmpeg library): capability probing, encoder arguments per
        // host and hardware accelerator, the process wrapper, RTP ports and demuxing, live streams and HKSV recordings in fMP4.
        .target(
            name: "HomeswiftFFmpeg",
            dependencies: [
                "Homeswift",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // Plugins live under Plugins/<Name>/ with their own Sources and Tests, the layout of a standalone
        // package, so moving one into its own repository is a directory move plus a Package.swift.
        .target(
            name: "HomeswiftElgatoKeyLights",
            dependencies: ["Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", .product(name: "Logging", package: "swift-log")],
            path: "Plugins/ElgatoKeyLights/Sources"
        ),
        .target(
            name: "HomeswiftPhilipsAmbilightTV",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/PhilipsAmbilightTV/Sources"
        ),
        .target(
            name: "HomeswiftDolphinPoolCleaner",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/DolphinPoolCleaner/Sources"
        ),
        .target(
            name: "HomeswiftDysonPureCool",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/DysonPureCool/Sources"
        ),
        .target(
            name: "HomeswiftUniFiAccess",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/UniFiAccess/Sources"
        ),
        .target(
            name: "HomeswiftDaikinCloud",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/DaikinCloud/Sources"
        ),
        .target(
            name: "HomeswiftEWeLink",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/EWeLink/Sources"
        ),
        .target(
            name: "HomeswiftLGThinQ",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/LGThinQ/Sources"
        ),
        .target(
            name: "HomeswiftGovee",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/Govee/Sources"
        ),
        .target(
            name: "HomeswiftUniFiProtect",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", "HomeswiftFFmpeg",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/UniFiProtect/Sources"
        ),
        .target(
            name: "HomeswiftWingman",
            dependencies: ["Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", .product(name: "Logging", package: "swift-log")],
            path: "Plugins/Wingman/Sources"
        ),
        // The `homeswift` bridge: reads config.json and runs the plugins compiled in (Plugins.swift lists them).
        // The target is not named "homeswift": that is "Homeswift" on a case-insensitive file system.
        .executableTarget(
            name: "HomeswiftCLI",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftAI", "HomeswiftMCP", "HomeswiftUI", "HomeswiftElgatoKeyLights", "HomeswiftPhilipsAmbilightTV", "HomeswiftDolphinPoolCleaner", "HomeswiftDysonPureCool", "HomeswiftUniFiAccess", "HomeswiftDaikinCloud", "HomeswiftEWeLink", "HomeswiftLGThinQ", "HomeswiftGovee", "HomeswiftUniFiProtect", "HomeswiftWingman",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            exclude: ["Info.plist"],
            // macOS reads a command-line tool's Info.plist from its __TEXT,__info_plist section. CoreBluetooth stops a
            // process whose Info.plist has no NSBluetoothAlwaysUsageDescription, so the Govee plugin's Bluetooth
            // needs it. Unsafe flags are allowed in the root package only; nothing depends on this target.
            linkerSettings: [
                .unsafeFlags(
                    ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", Context.packageDirectory + "/Sources/HomeswiftCLI/Info.plist"],
                    .when(platforms: [.macOS])),
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
            name: "HomeswiftUITests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftAI", "HomeswiftMCP", "HomeswiftUI", "HomeswiftElgatoKeyLights", "HomeswiftNetwork",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "HomeswiftMCPTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftAI", "HomeswiftMCP", "HomeswiftNetwork",
                .product(name: "Crypto", package: "swift-crypto"),
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
        // In-memory fakes of the network clients (an MQTT broker, a WebSocket) for plugin tests.
        .target(
            name: "HomeswiftNetworkTestSupport",
            dependencies: ["HomeswiftNetwork", .product(name: "NIOConcurrencyHelpers", package: "swift-nio")],
            path: "Tests/HomeswiftNetworkTestSupport"
        ),
        .testTarget(
            name: "HomeswiftNetworkTests",
            dependencies: [
                "HomeswiftNetwork", "HomeswiftNetworkTestSupport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "PhilipsAmbilightTVTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", "HomeswiftPhilipsAmbilightTV",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/PhilipsAmbilightTV/Tests"
        ),
        .testTarget(
            name: "HomeswiftFFmpegTests",
            dependencies: [
                "HomeswiftFFmpeg", "Homeswift",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "DolphinPoolCleanerTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", "HomeswiftNetworkTestSupport", "HomeswiftDolphinPoolCleaner",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/DolphinPoolCleaner/Tests"
        ),
        .testTarget(
            name: "DysonPureCoolTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", "HomeswiftDysonPureCool",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/DysonPureCool/Tests"
        ),
        .testTarget(
            name: "UniFiAccessTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", "HomeswiftUniFiAccess", "HomeswiftNetworkTestSupport",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/UniFiAccess/Tests"
        ),
        .testTarget(
            name: "DaikinCloudTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", "HomeswiftNetworkTestSupport", "HomeswiftDaikinCloud",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/DaikinCloud/Tests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "EWeLinkTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftEWeLink", "HomeswiftNetwork", "HomeswiftNetworkTestSupport",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/EWeLink/Tests"
        ),
        .testTarget(
            name: "LGThinQTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", "HomeswiftNetworkTestSupport", "HomeswiftLGThinQ",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/LGThinQ/Tests",
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "GoveeTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", "HomeswiftNetworkTestSupport", "HomeswiftGovee",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/Govee/Tests"
        ),
        .testTarget(
            name: "UniFiProtectTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", "HomeswiftNetworkTestSupport", "HomeswiftFFmpeg", "HomeswiftUniFiProtect",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/UniFiProtect/Tests"
        ),
        .testTarget(
            name: "WingmanTests",
            dependencies: [
                "Homeswift", "HomeswiftPlugin", "HomeswiftNetwork", "HomeswiftNetworkTestSupport", "HomeswiftWingman",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Plugins/Wingman/Tests"
        ),
    ]
)
