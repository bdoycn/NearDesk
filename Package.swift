// swift-tools-version: 6.0
// Copyright 2026 NearDesk Contributors
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "NearDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NearDesk", targets: ["NearDesk"])
    ],
    targets: [
        .target(
            name: "NearDeskCore",
            path: "Sources/NearDeskCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "NearDesk",
            dependencies: ["NearDeskCore"],
            path: "Sources/NearDesk",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NearDeskTests",
            dependencies: ["NearDeskCore"],
            path: "Tests/NearDeskTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
