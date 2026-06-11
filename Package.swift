// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "graft",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "graft", targets: ["graft"]),
        .library(name: "GraftCore", targets: ["GraftCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(
            name: "GraftCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .executableTarget(
            name: "graft",
            dependencies: [
                "GraftCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "GraftCoreTests",
            dependencies: ["GraftCore"]
        ),
    ]
)
