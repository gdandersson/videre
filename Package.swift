// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "videre",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "videre"
        )
    ]
)
