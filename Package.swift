// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Scout",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/smittytone/HighlighterSwift", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Scout",
            dependencies: [
                .product(name: "Highlighter", package: "HighlighterSwift"),
            ],
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
