// swift-tools-version: 6.0
//
// Package.swift
// Alamock
//

import PackageDescription

let package = Package(
    name: "Alamock",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(name: "Alamock", targets: ["Alamock"])
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.10.2")
    ],
    targets: [
        .target(
            name: "Alamock",
            dependencies: [.product(name: "Alamofire", package: "Alamofire")],
            path: "Sources/Alamock"
        ),
        .testTarget(
            name: "AlamockTests",
            dependencies: [
                "Alamock",
                .product(name: "Alamofire", package: "Alamofire"),
            ],
            path: "Tests/AlamockTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
