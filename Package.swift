// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Lighthouse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LighthouseGit", targets: ["LighthouseGit"]),
        .library(name: "LighthouseFixtures", targets: ["LighthouseFixtures"]),
    ],
    targets: [
        .target(name: "LighthouseGit"),
        // Test-harness only: generates throwaway git repos with known state.
        // Kept as a separate target so fixtures never ship in an app target.
        .target(name: "LighthouseFixtures"),
        .testTarget(
            name: "LighthouseGitTests",
            dependencies: ["LighthouseGit", "LighthouseFixtures"],
            // Command Line Tools-only machines (no Xcode, 2026-07): SwiftPM
            // passes the CLT frameworks directory as -I, but Swift Testing
            // ships there as Testing.framework, which needs -F — without it
            // `import Testing` fails with "no such module". Harmless where
            // the path doesn't exist (e.g. Xcode toolchains).
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                // Explicit because the shim imports Testing via -I (see
                // Scripts/bootstrap-clt-swift-testing.sh), which records no
                // framework autolink hint.
                .linkedFramework("Testing"),
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    // Testing.framework loads @rpath/lib_TestingInterop.dylib,
                    // which CLT ships one directory over.
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ])
            ]
        ),
    ]
)
