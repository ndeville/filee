// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FileeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FileeCore", targets: ["FileeCore"]),
    ],
    targets: [
        .target(name: "FileeCore"),
        .testTarget(name: "FileeCoreTests", dependencies: ["FileeCore"]),
    ]
)
