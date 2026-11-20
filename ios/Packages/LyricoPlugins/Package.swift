// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LyricoPlugins",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "LyricoPlugins", targets: ["LyricoPlugins"])
    ],
    targets: [
        .target(
            name: "LyricoPlugins",
            path: "Sources/LyricoPlugins"
        )
    ],
    swiftLanguageVersions: [.v5]
)
