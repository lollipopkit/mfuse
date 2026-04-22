// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MFuseSMB",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MFuseSMB", targets: ["MFuseSMB"]),
    ],
    dependencies: [
        .package(path: "../MFuseCore"),
        .package(url: "https://github.com/kishikawakatsumi/SMBClient.git", .upToNextMinor(from: "0.3.1")),
    ],
    targets: [
        .target(
            name: "MFuseSMB",
            dependencies: [
                "MFuseCore",
                "SMBClient",
            ]
        ),
        .testTarget(
            name: "MFuseSMBTests",
            dependencies: ["MFuseSMB"]
        ),
    ]
)
