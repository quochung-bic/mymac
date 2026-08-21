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
        // The app itself is a library, not the executable. SwiftPM cannot link
        // a test target against an executable, and leaving the app layer here
        // untested is what let a broken login-item message and a timeout that
        // could never fire both ship.
        .target(
            name: "MyMacUI",
            dependencies: ["MyMacCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MyMac",
            dependencies: ["MyMacUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MyMacCoreTests",
            dependencies: ["MyMacCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MyMacUITests",
            dependencies: ["MyMacUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
