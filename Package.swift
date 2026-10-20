// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "wpc-migrate",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "wpc-migrate", targets: ["wpc-migrate"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "wpc-migrate",
            dependencies: [
                "WPCMigrateKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "WPCMigrateKit"),
        .testTarget(name: "WPCMigrateKitTests", dependencies: ["WPCMigrateKit"]),
    ]
)
