// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MFuseOneDrive",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MFuseOneDrive", targets: ["MFuseOneDrive"]),
    ],
    dependencies: [
        .package(path: "../MFuseCore"),
    ],
    targets: [
        .target(
            name: "MFuseOneDrive",
            dependencies: ["MFuseCore"]
        ),
        .testTarget(
            name: "MFuseOneDriveTests",
            dependencies: ["MFuseOneDrive"]
        ),
    ]
)
