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
        // Pinned to exact versions matching Package.resolved for reproducible builds.
        // Update together with Package.resolved (dependabot will open PRs for these).
        .package(url: "https://github.com/LebJe/TOMLKit.git", exact: "0.6.0"),
        .package(
            url: "https://github.com/AzureAD/microsoft-authentication-library-for-objc",
            exact: "2.13.0"
        ),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/Alamofire/Alamofire.git", exact: "5.12.0"),
    ],
    targets: [
        .target(
            name: "OfemKit",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "MSAL", package: "microsoft-authentication-library-for-objc"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Alamofire", package: "Alamofire"),
            ],
            linkerSettings: [
                .linkedFramework("FileProvider"),
            ]
        ),
        .testTarget(
            name: "OfemKitTests",
            dependencies: ["OfemKit"],
            linkerSettings: [
                .linkedFramework("FileProvider"),
            ]
        ),
    ]
)
