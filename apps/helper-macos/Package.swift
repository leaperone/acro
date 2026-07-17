// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "acro-helper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "acro-helper",
            path: "Sources"
        )
    ]
)
