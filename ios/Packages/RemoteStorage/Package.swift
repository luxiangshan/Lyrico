// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RemoteStorage",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "RemoteStorage", targets: ["RemoteStorage"]),
    ],
    dependencies: [
        // libsmb2 wrapper (SMB2/3). 4.0.x keeps swift-tools-version 5.9 (main requires Swift 6 tools).
        .package(url: "https://github.com/amosavian/AMSMB2.git", .upToNextMinor(from: "4.0.3")),
    ],
    targets: [
        .target(
            name: "RemoteStorage",
            dependencies: [
                .product(name: "AMSMB2", package: "AMSMB2"),
            ]
        ),
        .testTarget(
            name: "RemoteStorageTests",
            dependencies: ["RemoteStorage"]
        ),
    ]
)
