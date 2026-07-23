import Foundation

/// Builds the self-contained HTML page the review WKWebView renders.
///
/// Security posture (spec §8, hard requirement): diff content is repo file
/// content — untrusted input rendered into HTML. No byte of it ever appears
/// raw in the page: the whole patch is embedded as base64 inside a JS string
/// literal and handed to diff2html (which emits it as text nodes). A strict
/// CSP forbids every network source; the only scripts are the vendored
/// diff2html bundle and our nonce'd bootstrap. The end-to-end proof is the
/// DIFFRENDER gate (hostile fixture through the real WKWebView, DOM
/// assertions) plus unit tests on this builder's output.
public enum DiffPageBuilder {

    /// Relative asset names; the app layer stages the vendored files next to
    /// the generated page.
    public static let scriptAsset = "diff2html.min.js"
    public static let styleAsset = "diff2html.min.css"

    public static func page(diff: String, debugChecks: Bool = false) -> String {
        let payload = Data(diff.utf8).base64EncodedString()
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        let debugBlock = debugChecks ? """
        try {
            const container = document.getElementById('diff');
            const result = {
                scripts: container.querySelectorAll('script').length,
                imgHandlers: container.querySelectorAll('img[onerror],img[onload]').length,
                pwned: window.__pwned === true,
                hostileTextPresent: container.textContent.includes("<script>window.__pwned=true<\\/script>"),
                files: document.querySelectorAll('.d2h-file-wrapper').length,
            };
            window.webkit?.messageHandlers?.diffDebug?.postMessage(JSON.stringify(result));
        } catch (e) {
            window.webkit?.messageHandlers?.diffDebug?.postMessage('{"error":"' + String(e).replace(/"/g, "'") + '"}');
        }
        """ : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'nonce-\(nonce)'; style-src 'self' 'unsafe-inline'; img-src data:;">
        <link rel="stylesheet" href="\(styleAsset)">
        <style>
            body { margin: 0; font-family: -apple-system, sans-serif; }
            .d2h-wrapper { padding: 8px; }
            #empty { color: #888; padding: 24px; text-align: center; }
            /* Collapsible files: click a header to fold its body so long diffs
               scroll quickly. The header (the scroll anchor) always stays. */
            #lh-toolbar { position: sticky; top: 0; z-index: 10; display: none;
                gap: 8px; padding: 6px 8px; background: #fff;
                border-bottom: 1px solid #ddd; }
            #lh-toolbar button { font: inherit; font-size: 12px; padding: 2px 8px;
                cursor: pointer; }
            .d2h-file-header { cursor: pointer; }
            .lh-chevron { display: inline-block; width: 1em; margin-right: 2px;
                color: #888; transition: transform 0.1s; user-select: none; }
            .d2h-file-wrapper.lh-collapsed .lh-chevron { transform: rotate(-90deg); }
            .d2h-file-wrapper.lh-collapsed .d2h-file-diff,
            .d2h-file-wrapper.lh-collapsed .d2h-files-diff { display: none; }
            @media (prefers-color-scheme: dark) { body { background: #1e1e1e; filter: invert(0.9) hue-rotate(180deg); } }
        </style>
        </head>
        <body>
        <div id="lh-toolbar">
            <button id="lh-collapse-all" type="button">Collapse all</button>
            <button id="lh-expand-all" type="button">Expand all</button>
        </div>
        <div id="diff"></div>
        <script src="\(scriptAsset)"></script>
        <script nonce="\(nonce)">
        (function () {
            const bytes = Uint8Array.from(atob("\(payload)"), c => c.charCodeAt(0));
            const diffText = new TextDecoder().decode(bytes);
            const container = document.getElementById('diff');
            if (diffText.trim().length === 0) {
                container.innerHTML = '<div id="empty">No changes vs base.</div>';
            } else {
                container.innerHTML = Diff2Html.html(diffText, {
                    drawFileList: false,
                    outputFormat: 'line-by-line',
                    matching: 'lines',
                });
            }
            // File anchors for the tree's click-to-scroll, plus per-file collapse
            // (fold a file's body to skim long diffs). The header stays visible
            // when collapsed, so it remains a valid scroll target.
            const anchors = {};
            const wrappers = document.querySelectorAll('.d2h-file-wrapper');
            wrappers.forEach(wrapper => {
                const name = wrapper.querySelector('.d2h-file-name');
                if (name) { anchors[name.textContent.trim()] = wrapper; }
                const header = wrapper.querySelector('.d2h-file-header');
                if (!header) return;
                const chevron = document.createElement('span');
                chevron.className = 'lh-chevron';
                chevron.textContent = '\\u25BE';
                header.insertBefore(chevron, header.firstChild);
                header.addEventListener('click', (e) => {
                    // Leave interactive header controls (copy button/links) alone.
                    if (e.target.closest('a, button, input')) { return; }
                    wrapper.classList.toggle('lh-collapsed');
                });
            });
            const setAllCollapsed = (collapsed) => wrappers.forEach(
                w => w.classList.toggle('lh-collapsed', collapsed));
            if (wrappers.length > 0) {
                const toolbar = document.getElementById('lh-toolbar');
                toolbar.style.display = 'flex';
                document.getElementById('lh-collapse-all')
                    .addEventListener('click', () => setAllCollapsed(true));
                document.getElementById('lh-expand-all')
                    .addEventListener('click', () => setAllCollapsed(false));
            }
            window.lighthouseScrollToFile = function (nameB64) {
                const raw = new TextDecoder().decode(
                    Uint8Array.from(atob(nameB64), c => c.charCodeAt(0)));
                const target = anchors[raw]
                    ?? Object.entries(anchors).find(([k]) => k.endsWith(raw))?.[1];
                if (target) {
                    target.classList.remove('lh-collapsed'); // reveal if folded
                    target.scrollIntoView({ behavior: 'smooth', block: 'start' });
                }
            };
            \(debugBlock)
        })();
        </script>
        </body>
        </html>
        """
    }

    /// A hostile patch exercising script tags, event-handler attributes, and
    /// broken-HTML edge content — the DIFFRENDER gate's fixture, kept next
    /// to the builder so the gate and unit tests share one definition.
    public static let hostileFixtureDiff = """
    diff --git a/evil.html b/evil.html
    new file mode 100644
    --- /dev/null
    +++ b/evil.html
    @@ -0,0 +1,4 @@
    +<script>window.__pwned=true</script>
    +<img src=x onerror="window.__pwned=true">
    +<div onclick="window.__pwned=true">"'&gt;</div>
    +</textarea></script><script nonce=steal>window.__pwned=true</script>
    diff --git a/normal file with spaces.swift b/normal file with spaces.swift
    new file mode 100644
    --- /dev/null
    +++ b/normal file with spaces.swift
    @@ -0,0 +1,1 @@
    +let ok = true
    """
}
