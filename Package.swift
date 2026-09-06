// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MetalShade",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MetalShade", targets: ["MetalShade"]),
        // Loaded into a game with DYLD_INSERT_LIBRARIES; see docs/INJECTION.md.
        .library(name: "MetalShadeInject", type: .dynamic, targets: ["MetalShadeInject"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.0.1")
    ],
    targets: [
        .executableTarget(
            name: "MetalShade",
            dependencies: ["KeyboardShortcuts"]
        ),
        .target(
            name: "MetalShadeInject",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Metal"),
            ]
        )
    ]
)
