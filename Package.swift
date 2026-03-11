// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Scout",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Scout",
            path: "Sources/Scout",
            exclude: [
                "Resources/Info.plist",
                "Resources/Scout.entitlements",
                "Resources/AppIcon.iconset",
                "Resources/AppIcon.svg",
                "Resources/AppIcon.icns",
                "Resources/build",
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
