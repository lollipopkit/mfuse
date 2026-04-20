// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MFuseWebDAV",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MFuseWebDAV", targets: ["MFuseWebDAV"]),
    ],
    dependencies: [
        .package(path: "../MFuseCore"),
    ],
    targets: [
        .target(
            name: "MFuseWebDAV",
            dependencies: ["MFuseCore"]
        ),
        .testTarget(
            name: "MFuseWebDAVTests",
            dependencies: ["MFuseWebDAV"]
        ),
    ]
)
