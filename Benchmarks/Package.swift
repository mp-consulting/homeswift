// swift-tools-version:6.1

import PackageDescription

// Benchmarks for the HAP server: `hap-bench` is a HomeKit controller that drives a server through pair
// setup, pair verify, reads, writes, events and concurrent load, measuring the server process as it goes;
// `hap-bench-server` is a Homeswift bridge with N lightbulbs, the counterpart of hap-nodejs/server.js.
//
// The controller carries its own copy of the pairing primitives (TLV8, SRP, the session framing) so it
// builds without `@testable import`, which would change the build of the server under test.
let package = Package(
    name: "homeswift-benchmarks",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "homeswift", path: ".."),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.11.0"),
    ],
    targets: [
        .target(name: "CBenchMath"),
        .executableTarget(
            name: "hap-bench",
            dependencies: [
                "CBenchMath",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "hap-bench-server",
            dependencies: [
                .product(name: "Homeswift", package: "homeswift"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "bridge-bench-server",
            dependencies: [
                .product(name: "Homeswift", package: "homeswift"),
                .product(name: "HomeswiftPlugin", package: "homeswift"),
                .product(name: "HomeswiftAI", package: "homeswift"),
                .product(name: "HomeswiftMCP", package: "homeswift"),
                .product(name: "HomeswiftUI", package: "homeswift"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
    ]
)
