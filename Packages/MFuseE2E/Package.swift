// swift-tools-version: 5.9
import PackageDescription

// End-to-end tests of every backend against real servers. Skipped unless MFUSE_E2E_HOST is
// set; see `make test-e2e` and README.md.
let package = Package(
    name: "MFuseE2E",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../MFuseCore"),
        .package(path: "../MFuseSFTP"),
        .package(path: "../MFuseS3"),
        .package(path: "../MFuseWebDAV"),
        .package(path: "../MFuseSMB"),
        .package(path: "../MFuseFTP"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0")
    ],
    targets: [
        .target(
            name: "MFuseE2E",
            dependencies: [.product(name: "MFuseCore", package: "MFuseCore")]
        ),
        .testTarget(
            name: "MFuseE2ETests",
            dependencies: [
                "MFuseE2E",
                .product(name: "MFuseCore", package: "MFuseCore"),
                .product(name: "MFuseSFTP", package: "MFuseSFTP"),
                .product(name: "MFuseS3", package: "MFuseS3"),
                .product(name: "MFuseWebDAV", package: "MFuseWebDAV"),
                .product(name: "MFuseSMB", package: "MFuseSMB"),
                .product(name: "MFuseFTP", package: "MFuseFTP"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]
        )
    ]
)
