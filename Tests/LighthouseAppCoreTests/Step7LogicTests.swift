import Foundation
import Testing
import LighthouseTaskEngine
@testable import LighthouseAppCore

@Suite("PrerequisiteChecks")
struct PrerequisiteChecksTests {

    @Test(arguments: [
        ("git version 2.50.1 (Apple Git-155)", 2, 50),
        ("git version 2.35.0", 2, 35),
        ("git version 2.9.5", 2, 9),
        ("git version 3.0", 3, 0),
    ])
    func parsesLeadingVersion(output: String, major: Int, minor: Int) {
        let v = PrerequisiteChecks.parseGitVersion(output)
        #expect(v?.major == major)
        #expect(v?.minor == minor)
    }

    @Test func rejectsUnparseable() {
        #expect(PrerequisiteChecks.parseGitVersion("git version") == nil)
        #expect(PrerequisiteChecks.parseGitVersion("no numbers here") == nil)
    }

    @Test func minimumComparison() {
        #expect(PrerequisiteChecks.gitMeetsMinimum(.init(major: 2, minor: 50)))
        #expect(PrerequisiteChecks.gitMeetsMinimum(.init(major: 2, minor: 35)))
        #expect(!PrerequisiteChecks.gitMeetsMinimum(.init(major: 2, minor: 34)))
        #expect(!PrerequisiteChecks.gitMeetsMinimum(.init(major: 1, minor: 99)))
        #expect(PrerequisiteChecks.gitMeetsMinimum(.init(major: 3, minor: 0)))
    }

    @Test func socketPathLimit() {
        #expect(PrerequisiteChecks.socketPathFits("/tmp/x.sock"))
        #expect(!PrerequisiteChecks.socketPathFits(String(repeating: "a", count: 104)))
        #expect(PrerequisiteChecks.socketPathFits(String(repeating: "a", count: 103)))
    }
}
