import Foundation
import SwiftUI
import WebKit
import LighthouseAppCore

/// Builds the locked-down WKWebView the review pane uses, and stages the
/// generated page next to the vendored renderer assets.
///
/// Lockdown (spec §8 — diff content is untrusted repo content):
///  - navigation delegate denies EVERYTHING except file: URLs inside the
///    render directory (the initial load and reloads);
///  - CSP inside the page forbids all network sources (DiffPageBuilder);
///  - content is base64-embedded, never raw in HTML;
///  - the only JS bridge is the receive-only "diffDebug" handler used by the
///    DIFFRENDER gate.
@MainActor
enum DiffWebViewFactory {

    static func makeRenderDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lighthouse-diff-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for asset in [DiffPageBuilder.scriptAsset, DiffPageBuilder.styleAsset] {
            guard let source = Bundle.module.url(
                forResource: (asset as NSString).deletingPathExtension,
                withExtension: (asset as NSString).pathExtension,
                subdirectory: "Resources/diff2html")
            else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSFilePathErrorKey: "bundled renderer asset \(asset) missing"])
            }
            try FileManager.default.copyItem(
                at: source, to: dir.appendingPathComponent(asset))
        }
        return dir
    }

    static func makeWebView(
        renderDirectory: URL, navigationGate: LocalOnlyNavigationDelegate
    ) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            navigationGate, name: "diffDebug")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = navigationGate
        webView.setValue(false, forKey: "drawsBackground") // match pane background
        return webView
    }

    static func load(page html: String, into webView: WKWebView, renderDirectory: URL) throws {
        let index = renderDirectory.appendingPathComponent("index.html")
        try Data(html.utf8).write(to: index)
        webView.loadFileURL(index, allowingReadAccessTo: renderDirectory)
    }
}

/// Denies every navigation that is not a file: URL inside the render
/// directory, and receives the gate's diffDebug messages.
final class LocalOnlyNavigationDelegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let allowedRoot: URL
    private let onDebugMessage: @MainActor (String) -> Void

    init(allowedRoot: URL, onDebugMessage: @escaping @MainActor (String) -> Void = { _ in }) {
        self.allowedRoot = allowedRoot.resolvingSymlinksInPath()
        self.onDebugMessage = onDebugMessage
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, url.isFileURL,
              url.resolvingSymlinksInPath().path.hasPrefix(allowedRoot.path) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "diffDebug", let body = message.body as? String else { return }
        let handler = onDebugMessage
        Task { @MainActor in handler(body) }
    }
}

/// Hosts the model-owned WKWebView; fills the proposal like the terminal
/// does (same representable sizing scar — see TerminalHostView).
struct DiffWebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(
            width: proposal.width ?? nsView.frame.width,
            height: proposal.height ?? nsView.frame.height)
    }

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
