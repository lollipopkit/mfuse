// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MFuseCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MFuseCore", targets: ["MFuseCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/JoshBashed/blake3-swift.git", exact: "0.2.2"),
    ],
    targets: [
        .target(
            name: "MFuseCore",
            dependencies: [
                .product(name: "BLAKE3", package: "blake3-swift"),
            ],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedFramework("FileProvider"),
            ]
        ),
        .testTarget(
            name: "MFuseCoreTests",
            dependencies: ["MFuseCore"]
        ),
    ]
)
