// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MFuseTestSupport",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MFuseTestSupport", targets: ["MFuseTestSupport"])
    ],
    dependencies: [
        .package(path: "../MFuseCore")
    ],
    targets: [
        .target(
            name: "MFuseTestSupport",
            dependencies: ["MFuseCore"]
        )
    ]
)
