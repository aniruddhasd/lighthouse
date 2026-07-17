import Foundation
import Testing
@testable import LighthouseAppCore

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {

    // MARK: No-match cases first

    @Test func nonSubsequenceDoesNotMatch() {
        #expect(FuzzyMatcher.score(query: "xyz", candidate: "payments-fix") == nil)
        #expect(FuzzyMatcher.score(query: "paymentsx", candidate: "payments") == nil)
        #expect(FuzzyMatcher.score(query: "ba", candidate: "ab") == nil) // order matters
    }

    @Test func queryLongerThanCandidateDoesNotMatch() {
        #expect(FuzzyMatcher.score(query: "abcdef", candidate: "abc") == nil)
    }

    @Test func emptyCandidateOnlyMatchesEmptyQuery() {
        #expect(FuzzyMatcher.score(query: "a", candidate: "") == nil)
        #expect(FuzzyMatcher.score(query: "", candidate: "") == 0)
    }

    @Test func hostileInputDoesNotCrash() {
        let nasty = "$(rm -rf /) `evil` \u{0} \n\t 🚨🚨🚨 \u{202E}reversed"
        #expect(FuzzyMatcher.score(query: nasty, candidate: nasty) != nil)
        #expect(FuzzyMatcher.score(query: "💥", candidate: "plain") == nil)
        _ = FuzzyMatcher.score(query: String(repeating: "a", count: 10_000),
                               candidate: String(repeating: "ab", count: 10_000))
    }

    // MARK: Matching semantics

    @Test func emptyQueryMatchesEverythingWithZero() {
        #expect(FuzzyMatcher.score(query: "", candidate: "anything") == 0)
    }

    @Test func caseInsensitive() {
        #expect(FuzzyMatcher.score(query: "PAY", candidate: "payments-fix") != nil)
        #expect(FuzzyMatcher.score(query: "pay", candidate: "PAYMENTS-FIX") != nil)
    }

    @Test func diacriticInsensitive() {
        #expect(FuzzyMatcher.score(query: "cafe", candidate: "Café Menü Fix") != nil)
        #expect(FuzzyMatcher.score(query: "café", candidate: "cafe menu fix") != nil)
        #expect(FuzzyMatcher.score(query: "menu", candidate: "Café Menü Fix") != nil)
    }

    @Test func consecutiveMatchesBeatScattered() throws {
        let consecutive = try #require(FuzzyMatcher.score(query: "pay", candidate: "payments"))
        let scattered = try #require(FuzzyMatcher.score(query: "pay", candidate: "p-a-y-x"))
        #expect(consecutive > scattered)
    }

    @Test func wordBoundaryMatchesBeatMidWord() throws {
        let boundary = try #require(FuzzyMatcher.score(query: "fix", candidate: "payments fix"))
        let midWord = try #require(FuzzyMatcher.score(query: "fix", candidate: "prefixation"))
        #expect(boundary > midWord)
    }

    @Test func rankingIsDeterministic() {
        for _ in 0..<10 {
            #expect(FuzzyMatcher.score(query: "pfix", candidate: "payments-fix")
                == FuzzyMatcher.score(query: "pfix", candidate: "payments-fix"))
        }
    }

    @Test func abbreviationAcrossBoundaries() {
        // "pf" should hit "payments-fix" via the two word starts.
        #expect(FuzzyMatcher.score(query: "pf", candidate: "payments-fix") != nil)
    }
}

@Suite("Branch slug")
struct BranchSlugTests {
    @Test(arguments: [
        ("Fix Payments API", "task/fix-payments-api"),
        ("  spaces   everywhere  ", "task/spaces-everywhere"),
        ("Émigré Café", "task/emigre-cafe"),
        ("weird!!!chars###here", "task/weird-chars-here"),
        ("--already-dashed--", "task/already-dashed"),
        ("MixedCASE123", "task/mixedcase123"),
        ("", "task/new"),
        ("!!!", "task/new"),
    ])
    func slugs(input: String, expected: String) {
        #expect(AppModel.branchSlug(from: input) == expected)
    }
}
