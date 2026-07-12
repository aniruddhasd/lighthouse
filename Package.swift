// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "Lighthouse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LighthouseGit", targets: ["LighthouseGit"]),
        .library(name: "LighthouseTaskEngine", targets: ["LighthouseTaskEngine"]),
        .library(name: "LighthouseAdapter", targets: ["LighthouseAdapter"]),
        .library(name: "LighthouseAppCore", targets: ["LighthouseAppCore"]),
        .library(name: "LighthouseFixtures", targets: ["LighthouseFixtures"]),
        .executable(name: "Lighthouse", targets: ["LighthouseApp"]),
    ],
    dependencies: [
        // Terminal emulation + local pty (spec §4 consumed contracts).
        // Latest stable verified against GitHub releases 2026-07-09.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.13.0"),
    ],
    targets: [
        .target(name: "LighthouseGit"),
        .target(name: "LighthouseTaskEngine", dependencies: ["LighthouseGit"]),
        .target(name: "LighthouseAdapter", dependencies: ["LighthouseGit", "LighthouseTaskEngine"]),
        // View-model layer: everything the app does that is testable without
        // a UI — kept free of AppKit/SwiftUI imports on purpose.
        .target(
            name: "LighthouseAppCore",
            dependencies: ["LighthouseGit", "LighthouseTaskEngine", "LighthouseAdapter"]),
        // The macOS app: SwiftUI views, SwiftTerm embedding, wiring only.
        .executableTarget(
            name: "LighthouseApp",
            dependencies: [
                "LighthouseAppCore", "LighthouseAdapter", "LighthouseTaskEngine", "LighthouseGit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            // Vendored diff renderer (docs/diff-renderer.md) — fully offline.
            resources: [.copy("Resources")]),
        // Test-harness only: generates throwaway git repos with known state.
        // Kept as a separate target so fixtures never ship in an app target.
        .target(name: "LighthouseFixtures"),
        .testTarget(
            name: "LighthouseGitTests",
            dependencies: ["LighthouseGit", "LighthouseFixtures"]),
        .testTarget(
            name: "LighthouseTaskEngineTests",
            dependencies: ["LighthouseTaskEngine", "LighthouseGit", "LighthouseFixtures"]),
        .testTarget(
            name: "LighthouseAdapterTests",
            dependencies: [
                "LighthouseAdapter", "LighthouseGit", "LighthouseTaskEngine", "LighthouseFixtures",
            ]),
        .testTarget(
            name: "LighthouseAppCoreTests",
            dependencies: [
                "LighthouseAppCore", "LighthouseAdapter", "LighthouseTaskEngine", "LighthouseGit",
                "LighthouseFixtures",
            ]),
        .testTarget(
            name: "LighthouseAppTests",
            dependencies: ["LighthouseApp", "LighthouseAdapter"]),
    ]
)
