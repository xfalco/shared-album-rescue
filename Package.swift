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
            ],
            linkerSettings: [
                // Embed bundle identity into the bare binary; photolibraryd rejects
                // identity-less XPC clients (endless CoreData 4097 retries). Path is
                // relative to the package root — build from there (Scripts/build-app.sh does).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "shared-album-rescueTests",
            dependencies: ["shared-album-rescue"]
        ),
    ]
)
