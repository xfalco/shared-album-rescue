// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "shared-album-rescue",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "shared-album-rescue",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "shared-album-rescueTests",
            dependencies: ["shared-album-rescue"]
        ),
    ]
)
