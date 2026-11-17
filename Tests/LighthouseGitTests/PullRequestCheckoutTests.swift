import Foundation
import Testing
@testable import LighthouseGit

/// The pure, offline contracts of the PR checkout: which references are
/// accepted (option-injection guard included) and the local branch naming. The
/// gh/network path is exercised manually, not here.
@Suite("PullRequestCheckout reference validation")
struct PullRequestCheckoutTests {

    @Test func acceptsBarePRNumbers() {
        #expect(PullRequestCheckout.isValidReference("14"))
        #expect(PullRequestCheckout.isValidReference("  42  ")) // trimmed
    }

    @Test func acceptsPullRequestURLs() {
        #expect(PullRequestCheckout.isValidReference("https://github.com/org/repo/pull/14"))
        #expect(PullRequestCheckout.isValidReference("https://ghe.corp/team/svc/pull/3"))
    }

    @Test func rejectsOptionLookalikesAndJunk() {
        // A leading dash would reach gh's option parser.
        #expect(!PullRequestCheckout.isValidReference("--repo=/etc/passwd"))
        #expect(!PullRequestCheckout.isValidReference("-14"))
        #expect(!PullRequestCheckout.isValidReference(""))
        #expect(!PullRequestCheckout.isValidReference("not-a-pr"))
        #expect(!PullRequestCheckout.isValidReference("https://github.com/org/repo")) // no /pull/
    }

    @Test func localBranchIsCollisionSafePrefix() {
        #expect(PullRequestCheckout.localBranch(for: 14) == "pr-14")
        #expect(PullRequestCheckout.localBranch(for: 3) == "pr-3")
    }
}
