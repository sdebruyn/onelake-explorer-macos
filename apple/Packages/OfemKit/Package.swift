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
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "OfemKit",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        .testTarget(
            name: "OfemKitTests",
            dependencies: ["OfemKit"]
        ),
    ]
)
