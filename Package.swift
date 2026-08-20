// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MyMac", targets: ["MyMac"]),
        .library(name: "MyMacCore", targets: ["MyMacCore"]),
    ],
    targets: [
        .target(
            name: "MyMacCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MyMac",
            dependencies: ["MyMacCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MyMacCoreTests",
            dependencies: ["MyMacCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
