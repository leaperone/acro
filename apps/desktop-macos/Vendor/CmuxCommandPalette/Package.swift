// swift-tools-version: 6.0
// acro 改动:去掉 CmuxFoundation 依赖(FocusStealingResponder 已内置)、移除测试 target。

import PackageDescription

let package = Package(
    name: "CmuxCommandPalette",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxCommandPalette",
            targets: ["CmuxCommandPalette"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxCommandPalette",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
