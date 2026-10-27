// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Webby",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Webby", targets: ["Webby"]),
        .executable(name: "webby-bridge", targets: ["WebbyBridge"]),
    ],
    targets: [
        .target(name: "WebbyCore"),
        .executableTarget(name: "Webby", dependencies: ["WebbyCore"]),
        .executableTarget(name: "WebbyBridge", dependencies: ["WebbyCore"]),
        .testTarget(name: "WebbyCoreTests", dependencies: ["WebbyCore"]),
    ],
    swiftLanguageModes: [.v6]
)
