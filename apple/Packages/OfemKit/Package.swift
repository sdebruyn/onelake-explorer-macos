// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "OfemKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "OfemKit",
            targets: ["OfemKit"]
        ),
    ],
    targets: [
        .target(
            name: "OfemKit"
        ),
        .testTarget(
            name: "OfemKitTests",
            dependencies: ["OfemKit"]
        ),
    ]
)
