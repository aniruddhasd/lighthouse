import Foundation
import Testing
@testable import LighthouseApp

@Suite("SupervisorWiring")
struct SupervisorWiringTests {
    @Test func theMCPServerIsFoundBesideTheRunningExecutable() {
        let exe = URL(fileURLWithPath: "/Apps/Lighthouse.app/Contents/MacOS/Lighthouse")
        #expect(SupervisorWiring.mcpServerURL(executable: exe).path
                == "/Apps/Lighthouse.app/Contents/MacOS/lighthouse-supervisor-mcp")
    }

    @Test func withoutAnExecutableItPointsAtNothingRunnable() {
        let url = SupervisorWiring.mcpServerURL(executable: nil)
        #expect(!FileManager.default.isExecutableFile(atPath: url.path), "the runner must then refuse to start")
    }
}
