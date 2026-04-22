// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MFuseNFS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MFuseNFS", targets: ["MFuseNFS"]),
    ],
    dependencies: [
        .package(path: "../MFuseCore"),
    ],
    targets: [
        .target(
            name: "MFuseNFS",
            dependencies: ["MFuseCore"]
        ),
        .testTarget(
            name: "MFuseNFSTests",
            dependencies: ["MFuseNFS"]
        ),
    ]
)
