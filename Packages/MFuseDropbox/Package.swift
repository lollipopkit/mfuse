// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MFuseDropbox",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MFuseDropbox", targets: ["MFuseDropbox"]),
    ],
    dependencies: [
        .package(path: "../MFuseCore"),
    ],
    targets: [
        .target(
            name: "MFuseDropbox",
            dependencies: ["MFuseCore"]
        ),
        .testTarget(
            name: "MFuseDropboxTests",
            dependencies: ["MFuseDropbox"]
        ),
    ]
)
