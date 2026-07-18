// swift-tools-version:5.9
import PackageDescription

// libghostty 链接方式取自 muxy(MIT, Copyright (c) 2026 Muxy)。
// 构建前先跑 scripts/setup-ghostty.sh 下载 GhosttyKit.xcframework 与运行资源。
let package = Package(
    name: "AcroDesktop",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Vendor/ 下是整包搬运的 cmux SPM 包(GPL-3.0-or-later),见 Vendor/NOTICE.md
        .package(path: "Vendor/bonsplit"),
        .package(path: "Vendor/CmuxPanes"),
        .package(path: "Vendor/CmuxCommandPalette"),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            path: "GhosttyKit",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "AcroDesktop",
            dependencies: [
                "GhosttyKit",
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "CmuxPanes", package: "CmuxPanes"),
                .product(name: "CmuxCommandPalette", package: "CmuxCommandPalette"),
            ],
            path: "Sources",
            linkerSettings: [
                .unsafeFlags([
                    "GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a",
                ]),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Speech"),
                .linkedFramework("UserNotifications"),
                .linkedLibrary("c++"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "AcroDesktopTests",
            dependencies: ["AcroDesktop"],
            path: "Tests"
        ),
    ]
)
