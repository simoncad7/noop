// swift-tools-version: 5.9
import PackageDescription

// Clean-room Xiaomi Smart Band 10 BLE protocol package. Mirrors the layout of Packages/OuraProtocol:
// a pure library target (zero CoreBluetooth, headless-testable) and a test target.
//
// The band speaks Xiaomi SPPv2 framing over its FE95 service and requires an EC/CRC auth handshake
// (the 32-hex binding key) before any health command. All of that lives here as pure byte codecs and
// a transport-agnostic Session state machine — the CoreBluetooth driver is an app-layer concern.
// No UIKit / CoreBluetooth imports: builds and tests on Linux.
let package = Package(
    name: "SmartBand10Protocol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SmartBand10Protocol", targets: ["SmartBand10Protocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.37.0"),
    ],
    targets: [
        .target(
            name: "SmartBand10Protocol",
            dependencies: [
                .product(name: "CryptoSwift", package: "CryptoSwift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "SmartBand10ProtocolTests",
            dependencies: [
                "SmartBand10Protocol",
                .product(name: "CryptoSwift", package: "CryptoSwift"),
            ],
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
