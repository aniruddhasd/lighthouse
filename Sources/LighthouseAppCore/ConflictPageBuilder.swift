import Foundation

/// Renders a text conflict's zdiff3 blocks (current / base / incoming) into a
/// self-contained HTML page for the locked WKWebView. Same discipline as
/// DiffPageBuilder: every byte of untrusted repo content is base64-embedded
/// and decoded into TEXT nodes — never raw in the markup — under a
/// default-src 'none' CSP with a per-page script nonce. Display only; the
/// Accept Current/Incoming/Both actions are native SwiftUI controls (zero
/// action-JS bridge — strictly less attack surface than in-page handlers).
public enum ConflictPageBuilder {
    public static let scriptAsset = "diff2html.min.js" // unused here but keeps CSP shape identical
    public static let styleAsset = "diff2html.min.css"

    /// Encodes the blocks as JSON→base64 so no side content is ever raw HTML.
    public static func page(path: String, blocks: [ConflictBlockView], debugChecks: Bool = false) -> String {
        struct Wire: Encodable { let current: String; let base: String?; let incoming: String }
        let wire = blocks.map { Wire(current: $0.current, base: $0.base, incoming: $0.incoming) }
        let json = (try? JSONEncoder().encode(wire)) ?? Data("[]".utf8)
        let payload = json.base64EncodedString()
        let pathPayload = Data(path.utf8).base64EncodedString()
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        let debugBlock = debugChecks ? """
        try {
            const root = document.getElementById('blocks');
            const result = {
                scripts: root.querySelectorAll('script').length,
                handlers: root.querySelectorAll('[onerror],[onclick],[onload]').length,
                pwned: window.__pwned === true,
                hostileTextPresent: root.textContent.includes("<script>window.__pwned=true<\\/script>"),
                blocks: root.querySelectorAll('.lh-block').length,
            };
            window.webkit?.messageHandlers?.diffDebug?.postMessage(JSON.stringify(result));
        } catch (e) {
            window.webkit?.messageHandlers?.diffDebug?.postMessage('{"error":"'+String(e).replace(/"/g,"'")+'"}');
        }
        """ : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline';">
        <style>
            body { margin: 0; font-family: -apple-system, sans-serif; font-size: 12px; }
            h2 { font-size: 13px; padding: 8px 10px; margin: 0; border-bottom: 1px solid #ccc; }
            .lh-block { border-bottom: 1px solid #ddd; padding: 6px 10px; }
            .lh-side { white-space: pre-wrap; font-family: ui-monospace, monospace;
                       padding: 4px 6px; border-radius: 4px; margin: 3px 0; }
            .lh-current { background: rgba(0,128,0,0.10); }
            .lh-base    { background: rgba(128,128,128,0.10); }
            .lh-incoming{ background: rgba(0,0,255,0.10); }
            .lh-label { font-weight: 600; opacity: 0.7; }
            @media (prefers-color-scheme: dark) { body { background:#1e1e1e; color:#ddd; } }
        </style>
        </head>
        <body>
        <h2 id="title"></h2>
        <div id="blocks"></div>
        <script nonce="\(nonce)">
        (function () {
            const dec = b => new TextDecoder().decode(Uint8Array.from(atob(b), c => c.charCodeAt(0)));
            document.getElementById('title').textContent = dec("\(pathPayload)");
            const blocks = JSON.parse(dec("\(payload)"));
            const root = document.getElementById('blocks');
            blocks.forEach((b, i) => {
                const wrap = document.createElement('div');
                wrap.className = 'lh-block';
                const mk = (cls, label, text) => {
                    const d = document.createElement('div');
                    d.className = 'lh-side ' + cls;
                    const l = document.createElement('div');
                    l.className = 'lh-label';
                    l.textContent = label + ' (block ' + (i + 1) + ')';
                    const body = document.createElement('div');
                    body.textContent = text;      // TEXT node — never parsed as HTML
                    d.appendChild(l); d.appendChild(body);
                    return d;
                };
                wrap.appendChild(mk('lh-current', 'Current', b.current));
                if (b.base != null) wrap.appendChild(mk('lh-base', 'Base', b.base));
                wrap.appendChild(mk('lh-incoming', 'Incoming', b.incoming));
                root.appendChild(wrap);
            });
            if (blocks.length === 0) {
                root.innerHTML = '<div style="padding:20px;opacity:.6">No text blocks.</div>';
            }
            \(debugBlock)
        })();
        </script>
        </body>
        </html>
        """
    }

    /// Hostile fixture reused by the unit test and the render gate.
    public static let hostileBlocks: [ConflictBlockView] = [
        ConflictBlockView(
            id: 0,
            current: "<script>window.__pwned=true</script>\n",
            base: "<img src=x onerror=\"window.__pwned=true\">\n",
            incoming: "</textarea></script><script nonce=steal>window.__pwned=true</script>\n"),
    ]
}
