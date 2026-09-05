// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MetalShade",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MetalShade", targets: ["MetalShade"])],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1")
    ],
    targets: [
        .executableTarget(
            name: "MetalShade",
            dependencies: ["KeyboardShortcuts"]
        )
    ]
)
