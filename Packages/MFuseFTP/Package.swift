// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MFuseFTP",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MFuseFTP", targets: ["MFuseFTP"]),
    ],
    dependencies: [
        .package(path: "../MFuseCore"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.83.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.21.0"),
    ],
    targets: [
        .target(
            name: "MFuseFTP",
            dependencies: [
                "MFuseCore",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ]
        ),
        .testTarget(
            name: "MFuseFTPTests",
            dependencies: ["MFuseFTP"]
        ),
    ]
)
