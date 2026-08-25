// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FanControlCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FanControlCore", targets: ["FanControlCore"])
    ],
    targets: [
        .target(name: "FanControlCore"),
        .testTarget(name: "FanControlCoreTests", dependencies: ["FanControlCore"])
    ]
)
