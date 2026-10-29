// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Webby",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Webby", targets: ["Webby"]),
        .executable(name: "webby-bridge", targets: ["WebbyBridge"]),
    ],
    dependencies: [
        // Safe `.webbyskin` extraction and export (plan.md §5.4.6, Step 9a).
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(name: "WebbyCore"),
        .target(
            name: "WebbySkinArchive",
            dependencies: [
                "WebbyCore",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .executableTarget(name: "Webby", dependencies: ["WebbyCore", "WebbySkinArchive"]),
        .executableTarget(name: "WebbyBridge", dependencies: ["WebbyCore"]),
        .testTarget(name: "WebbyCoreTests", dependencies: ["WebbyCore"]),
        .testTarget(name: "WebbySkinArchiveTests", dependencies: ["WebbyCore", "WebbySkinArchive"]),
    ],
    swiftLanguageModes: [.v6]
)
