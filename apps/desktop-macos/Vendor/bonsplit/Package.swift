// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "bonsplit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Bonsplit", targets: ["Bonsplit"]),
    ],
    targets: [
        .target(name: "Bonsplit"),
    ]
)
