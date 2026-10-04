// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "MFuseNFS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MFuseNFS", targets: ["MFuseNFS"])
    ],
    dependencies: [
        .package(path: "../MFuseCore"),
        .package(url: "https://github.com/lollipopkit/nfs.swift.git", from: "0.2.0")
    ],
    targets: [
        .target(
            name: "MFuseNFS",
            dependencies: [
                "MFuseCore",
                .product(name: "NFS", package: "nfs.swift")
            ]
        ),
        .testTarget(
            name: "MFuseNFSTests",
            dependencies: ["MFuseNFS"]
        )
    ]
)
