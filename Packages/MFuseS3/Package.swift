// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MFuseS3",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MFuseS3", targets: ["MFuseS3"]),
    ],
    dependencies: [
        .package(path: "../MFuseCore"),
        .package(url: "https://github.com/soto-project/soto.git", from: "7.14.0"),
    ],
    targets: [
        .target(
            name: "MFuseS3",
            dependencies: [
                "MFuseCore",
                .product(name: "SotoS3", package: "soto"),
            ]
        ),
        .testTarget(
            name: "MFuseS3Tests",
            dependencies: ["MFuseS3"]
        ),
    ]
)
