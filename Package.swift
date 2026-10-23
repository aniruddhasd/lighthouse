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
        .library(name: "LighthouseSupervisor", targets: ["LighthouseSupervisor"]),
        .executable(name: "Lighthouse", targets: ["LighthouseApp"]),
        .executable(name: "lighthouse-supervisor-mcp", targets: ["LighthouseSupervisorMCP"]),
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
        // Supervisor tool surface (docs/orchestrator-design.md §10): read-only queries
        // over the app's own persisted state, and the MCP protocol that exposes them.
        // Pure Foundation — no UI, no network, no writes.
        .target(
            name: "LighthouseSupervisor",
            dependencies: ["LighthouseAppCore", "LighthouseAdapter", "LighthouseTaskEngine"]),
        // Thin stdio entry point: spawned by `claude --mcp-config`, never by the app.
        .executableTarget(
            name: "LighthouseSupervisorMCP",
            dependencies: ["LighthouseSupervisor", "LighthouseTaskEngine"]),
        // The macOS app: SwiftUI views, SwiftTerm embedding, wiring only.
        .executableTarget(
            name: "LighthouseApp",
            dependencies: [
                "LighthouseAppCore", "LighthouseAdapter", "LighthouseTaskEngine", "LighthouseGit",
                "LighthouseSupervisor",
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
            name: "LighthouseSupervisorTests",
            dependencies: [
                "LighthouseSupervisor", "LighthouseAppCore", "LighthouseAdapter",
                "LighthouseTaskEngine",
            ]),
        .testTarget(
            name: "LighthouseAppTests",
            dependencies: [
                "LighthouseApp", "LighthouseAdapter", "LighthouseGit",
                "LighthouseTaskEngine", "LighthouseFixtures",
            ]),
    ]
)
