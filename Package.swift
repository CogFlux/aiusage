// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIUsage",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-app updates. EdDSA-signed appcast; independent of Apple code signing.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        // Pure logic, no AppKit/SwiftUI: models, pace math, parsers, formatting.
        // This is the part meant to be ported to other languages (see docs/data-contract.md).
        .target(
            name: "AIUsageCore",
            path: "Sources/AIUsageCore"
        ),
        // The menu bar app.
        .executableTarget(
            name: "AIUsage",
            dependencies: [
                "AIUsageCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/AIUsage",
            resources: [.copy("Resources/aiusage-statusline.sh")],
            linkerSettings: [
                // Sparkle.framework is embedded in Contents/Frameworks by scripts/build-app.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // Tests as a plain executable: the Command Line Tools toolchain ships neither XCTest
        // nor Swift Testing, so `swift run AIUsageCoreChecks` is the test command. The
        // assertions map 1:1 onto XCTest should the project move to Xcode.
        .executableTarget(
            name: "AIUsageCoreChecks",
            dependencies: ["AIUsageCore"],
            path: "Tests/AIUsageCoreChecks"
        ),
    ]
)
