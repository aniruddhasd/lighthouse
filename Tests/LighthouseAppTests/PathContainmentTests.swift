import Foundation
import Testing
@testable import LighthouseApp

/// The WKWebView navigation gate must only allow file URLs INSIDE its render
/// directory. A raw `hasPrefix(root.path)` also accepted a sibling whose name
/// extends the root's — this pins the component-wise check that closed it.
@Suite("Navigation path containment")
struct PathContainmentTests {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func siblingWithExtendedNameIsRejected() {
        let root = url("/tmp/render-abc")
        // The exact bug: /tmp/render-abcEVIL shares the prefix but is a sibling.
        #expect(!LocalOnlyNavigationDelegate.isContained(url("/tmp/render-abcEVIL/index.html"), within: root))
        #expect(!LocalOnlyNavigationDelegate.isContained(url("/tmp/render-abc-other"), within: root))
    }

    @Test func legitimateChildrenAreAllowed() {
        let root = url("/tmp/render-abc")
        #expect(LocalOnlyNavigationDelegate.isContained(url("/tmp/render-abc/index.html"), within: root))
        #expect(LocalOnlyNavigationDelegate.isContained(url("/tmp/render-abc/diff2html.min.js"), within: root))
        #expect(LocalOnlyNavigationDelegate.isContained(url("/tmp/render-abc/sub/deep.css"), within: root))
    }

    @Test func theRootItselfIsAllowed() {
        let root = url("/tmp/render-abc")
        #expect(LocalOnlyNavigationDelegate.isContained(root, within: root))
    }

    @Test func unrelatedAndParentPathsRejected() {
        let root = url("/tmp/render-abc")
        #expect(!LocalOnlyNavigationDelegate.isContained(url("/etc/passwd"), within: root))
        #expect(!LocalOnlyNavigationDelegate.isContained(url("/tmp"), within: root))
        #expect(!LocalOnlyNavigationDelegate.isContained(url("/"), within: root))
    }

    @Test func traversalOutIsRejectedAfterStandardization() {
        let root = url("/tmp/render-abc")
        // ../render-abcEVIL/x standardizes to /tmp/render-abcEVIL/x → outside.
        #expect(!LocalOnlyNavigationDelegate.isContained(
            url("/tmp/render-abc/../render-abcEVIL/x"), within: root))
    }
}
