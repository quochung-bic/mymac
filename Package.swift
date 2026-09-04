// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyMacKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MyMacCore", targets: ["MyMacCore"]),
        // Vended so the Xcode app target can link the app layer. The
        // executable stays a single line; this is what it links too.
        .library(name: "MyMacUI", targets: ["MyMacUI"]),
        // A SwiftPM route to a runnable binary, for people who do not want to
        // install Xcode just to try the app. Named in lower case so it cannot
        // collide with the Xcode application target, which is `MyMac`: two
        // products of that name in one build graph is what made
        // TEST_TARGET_NAME resolve to the wrong one and broke the UI tests.
        .executable(name: "mymac", targets: ["MyMacExecutable"]),
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
        // Compiles the very same Sources/MyMac/main.swift the Xcode app target
        // does, so there is one entry point and no second copy to drift.
        .executableTarget(
            name: "MyMacExecutable",
            dependencies: ["MyMacUI"],
            path: "Sources/MyMac",
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
