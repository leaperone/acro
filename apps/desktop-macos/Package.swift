// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AcroDesktop",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AcroDesktop",
            path: "Sources"
        )
    ]
)
