// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyMacKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MyMac", targets: ["MyMac"]),
        .library(name: "MyMacCore", targets: ["MyMacCore"]),
        // Vended so the Xcode app target can link the app layer. The
        // executable stays a single line; this is what it links too.
        .library(name: "MyMacUI", targets: ["MyMacUI"]),
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
            name: "MyMacUIUnitTests",
            dependencies: ["MyMacUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
