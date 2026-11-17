// swift-tools-version: 6.0
import PackageDescription

let extensionSafe: [SwiftSetting] = [.unsafeFlags(["-application-extension"])]

let package = Package(
    name: "Clicksmith",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Clicksmith", targets: ["ClicksmithApp"]),
        .executable(name: "ClicksmithFinder", targets: ["ClicksmithFinder"]),
        .executable(name: "csx", targets: ["csx"]),
    ],
    targets: [
        // Extension-safe shared model: menu.json, requests, paths.
        .target(name: "ClicksmithKit", swiftSettings: extensionSafe),
        // All logic. Pure, tested.
        .target(name: "ClicksmithCore", dependencies: ["ClicksmithKit"]),
        .executableTarget(name: "ClicksmithApp", dependencies: ["ClicksmithCore", "ClicksmithKit"]),
        .executableTarget(
            name: "ClicksmithFinder",
            dependencies: ["ClicksmithKit"],
            swiftSettings: extensionSafe,
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-application-extension"]),
                .linkedFramework("FinderSync"),
            ]
        ),
        .executableTarget(name: "csx", dependencies: ["ClicksmithCore", "ClicksmithKit"]),
        .testTarget(name: "ClicksmithKitTests", dependencies: ["ClicksmithKit"]),
        .testTarget(name: "ClicksmithCoreTests", dependencies: ["ClicksmithCore"]),
    ]
)
