import Foundation
import Testing
import LighthouseTaskEngine
@testable import LighthouseAppCore

@Suite("FailureDescriber")
struct FailureDescriberTests {

    @Test func incompleteRollbackListsExactDebris() {
        let failure = TaskCreationFailure(
            repoPath: "/repos/two",
            cause: .setupScriptFailed(
                repoPath: "/repos/two", script: "setup.sh", exitCode: 7, stderr: "boom"),
            rollback: .incomplete(
                removed: [CreatedArtifact(
                    repoPath: "/repos/two", branch: "task/x", worktreePath: "/wt/two")],
                debris: [DebrisItem(
                    repoPath: "/repos/one", branch: "task/x", worktreePath: "/wt/one",
                    failure: "worktree: locked")]))
        let text = FailureDescriber.describe(failure)
        #expect(text.contains("/repos/two"))
        #expect(text.contains("exited 7"))
        #expect(text.contains("boom"))
        #expect(text.contains("ROLLBACK INCOMPLETE"))
        #expect(text.contains("/repos/one: branch 'task/x', worktree /wt/one"))
        #expect(text.contains("worktree: locked"))
    }

    @Test func preflightFailureSaysNothingWasModified() {
        let failure = TaskCreationFailure(
            repoPath: nil,
            cause: .invalidBranchName("bad name"),
            rollback: .notNeeded)
        let text = FailureDescriber.describe(failure)
        #expect(text.contains("before touching any repo"))
        #expect(text.contains("'bad name' is not a valid git branch name."))
        #expect(text.contains("No repos were modified."))
    }

    @Test func branchCollisionSaysPreexistingBranchUntouched() {
        let text = FailureDescriber.describe(
            TaskEngineError.branchAlreadyExists(repoPath: "/repos/api", branch: "task/fix"))
        #expect(text.contains("/repos/api"))
        #expect(text.contains("NOT touched"))
    }

    @Test func cleanRollbackNamesTheRepos() {
        let failure = TaskCreationFailure(
            repoPath: "/repos/three",
            cause: .envCopySourceMissing(repoPath: "/repos/three", entry: ".env"),
            rollback: .completed(removed: [
                CreatedArtifact(repoPath: "/repos/one", branch: "task/x", worktreePath: "/wt/1"),
                CreatedArtifact(repoPath: "/repos/two", branch: "task/x", worktreePath: "/wt/2"),
            ]))
        let text = FailureDescriber.describe(failure)
        #expect(text.contains("Rolled back cleanly"))
        #expect(text.contains("• /repos/one"))
        #expect(text.contains("• /repos/two"))
    }
}
