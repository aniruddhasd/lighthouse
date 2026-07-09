// swift-tools-version:6.1
import PackageDescription

// Command Line Tools-only machines (no Xcode, observed 2026-07 with CLT 26.x /
// Swift 6.3.2): SwiftPM passes the CLT frameworks directory as -I, but Swift
// Testing ships there as Testing.framework, which needs -F — without it
// `import Testing` fails with "no such module". These settings, plus
// Scripts/bootstrap-clt-swift-testing.sh, make `swift test` work. Harmless
// where the path doesn't exist (e.g. Xcode toolchains).
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltTestingSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-F", cltFrameworks])
]
let cltTestingLinkerSettings: [LinkerSetting] = [
    // Explicit because the bootstrap shim imports Testing via -I, which
    // records no framework autolink hint. Applied once (test products link
    // all test targets together, so one declaration reaches the bundle).
    .linkedFramework("Testing"),
    .unsafeFlags([
        "-F", cltFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
        // Testing.framework loads @rpath/lib_TestingInterop.dylib, which CLT
        // ships one directory over.
        "-Xlinker", "-rpath",
        "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
    ]),
]

let package = Package(
    name: "Lighthouse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LighthouseGit", targets: ["LighthouseGit"]),
        .library(name: "LighthouseTaskEngine", targets: ["LighthouseTaskEngine"]),
        .library(name: "LighthouseFixtures", targets: ["LighthouseFixtures"]),
    ],
    targets: [
        .target(name: "LighthouseGit"),
        .target(name: "LighthouseTaskEngine", dependencies: ["LighthouseGit"]),
        // Test-harness only: generates throwaway git repos with known state.
        // Kept as a separate target so fixtures never ship in an app target.
        .target(name: "LighthouseFixtures"),
        .testTarget(
            name: "LighthouseGitTests",
            dependencies: ["LighthouseGit", "LighthouseFixtures"],
            swiftSettings: cltTestingSwiftSettings,
            linkerSettings: cltTestingLinkerSettings
        ),
        .testTarget(
            name: "LighthouseTaskEngineTests",
            dependencies: ["LighthouseTaskEngine", "LighthouseGit", "LighthouseFixtures"],
            swiftSettings: cltTestingSwiftSettings
        ),
    ]
)
