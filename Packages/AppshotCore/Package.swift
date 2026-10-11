// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppshotCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AppshotCore", targets: ["AppshotCore"]),
    ],
    targets: [
        .target(name: "AppshotCore"),
        .testTarget(name: "AppshotCoreTests", dependencies: ["AppshotCore"]),
    ]
)
