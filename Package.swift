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
        .target(
            name: "CSearchfs",
            path: "Sources/CSearchfs",
            publicHeadersPath: "include"
        ),
        .target(
            name: "ScoutLib",
            dependencies: [
                .product(name: "Highlighter", package: "HighlighterSwift"),
                "CSearchfs",
            ],
            path: "Sources/ScoutLib",
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
                .copy("Resources/markdown-template.html"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .executableTarget(
            name: "Scout",
            dependencies: [
                "ScoutLib",
            ],
            path: "Sources/Scout",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "ScoutDropTests",
            dependencies: ["ScoutLib"],
            path: "Tests/ScoutDropTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
