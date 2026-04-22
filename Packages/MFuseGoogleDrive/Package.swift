// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MFuseGoogleDrive",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MFuseGoogleDrive", targets: ["MFuseGoogleDrive"]),
    ],
    dependencies: [
        .package(path: "../MFuseCore"),
    ],
    targets: [
        .target(
            name: "MFuseGoogleDrive",
            dependencies: ["MFuseCore"]
        ),
        .testTarget(
            name: "MFuseGoogleDriveTests",
            dependencies: ["MFuseGoogleDrive"]
        ),
    ]
)
