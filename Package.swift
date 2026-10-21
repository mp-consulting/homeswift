// swift-tools-version:6.1

import PackageDescription

let package = Package(
    name: "homeswift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Homeswift", targets: ["Homeswift"]),
        .executable(name: "homeswift-demo", targets: ["homeswift-demo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
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
        .executableTarget(name: "homeswift-demo", dependencies: ["Homeswift"]),
        .testTarget(
            name: "HomeswiftTests",
            dependencies: ["Homeswift", .product(name: "Logging", package: "swift-log")]
        ),
    ]
)
