// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MFuseSFTP",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MFuseSFTP", targets: ["MFuseSFTP"]),
    ],
    dependencies: [
        .package(path: "../MFuseCore"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
    ],
    targets: [
        .target(
            name: "MFuseSFTP",
            dependencies: [
                "MFuseCore",
                .product(name: "Citadel", package: "Citadel"),
            ]
        ),
        .testTarget(
            name: "MFuseSFTPTests",
            dependencies: ["MFuseSFTP"]
        ),
    ]
)
