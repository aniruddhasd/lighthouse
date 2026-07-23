import Foundation

/// Renders a repo file as read-only, escaped monospace text with line numbers
/// for the content viewer's locked WKWebView.
///
/// Same discipline as DiffPageBuilder (spec §8): file
/// content is untrusted repo content, so no byte of it — nor the filename —
/// ever appears raw in the markup. Both are base64-embedded and decoded
/// in-page into TEXT nodes only, under a `default-src 'none'` CSP with a
/// per-page script nonce. Line numbers and the `<pre>`/table are built by the
/// bootstrap; there is no highlighter and no external asset, so nothing loads
/// over the network and the CSP needs no `script-src 'self'`.
public enum FilePageBuilder {

    public static func page(content: String, filename: String, debugChecks: Bool = false) -> String {
        let payload = Data(content.utf8).base64EncodedString()
        let namePayload = Data(filename.utf8).base64EncodedString()
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        let debugBlock = debugChecks ? """
        try {
            const root = document.getElementById('file');
            const result = {
                scripts: root.querySelectorAll('script').length,
                handlers: root.querySelectorAll('[onerror],[onclick],[onload]').length,
                imgs: root.querySelectorAll('img').length,
                pwned: window.__pwned === true,
                hostileTextPresent: root.textContent.includes("<img src=x onerror=alert(1)>"),
                lines: root.querySelectorAll('.lh-line').length,
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
            table.lh-code { border-collapse: collapse; width: 100%;
                font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
            td.lh-gutter { text-align: right; padding: 0 10px; width: 1%; white-space: nowrap;
                color: #999; background: rgba(128,128,128,0.08); user-select: none;
                border-right: 1px solid rgba(128,128,128,0.25); }
            td.lh-line { padding: 0 10px; white-space: pre; }
            /* ⌘F jump target highlight. */
            tr.lh-hit td { background: rgba(255, 213, 0, 0.22); }
            #empty { color: #888; padding: 24px; text-align: center; }
            @media (prefers-color-scheme: dark) {
                body { background:#1e1e1e; color:#ddd; }
                tr.lh-hit td { background: rgba(255, 213, 0, 0.16); }
            }
        </style>
        </head>
        <body>
        <h2 id="title"></h2>
        <div id="file"></div>
        <script nonce="\(nonce)">
        (function () {
            const dec = b => new TextDecoder().decode(Uint8Array.from(atob(b), c => c.charCodeAt(0)));
            document.getElementById('title').textContent = dec("\(namePayload)");
            const text = dec("\(payload)");
            const root = document.getElementById('file');
            if (text.length === 0) {
                root.innerHTML = '<div id="empty">Empty file.</div>';
            } else {
                // Split preserving a trailing newline's empty last line only if
                // the file did not end with one (avoids a phantom blank row).
                let lines = text.split("\\n");
                if (lines.length > 1 && lines[lines.length - 1] === "") { lines.pop(); }
                const table = document.createElement('table');
                table.className = 'lh-code';
                const body = document.createElement('tbody');
                lines.forEach((line, i) => {
                    const row = document.createElement('tr');
                    row.id = 'L' + (i + 1);       // ⌘F jump anchor (1-based)
                    const gutter = document.createElement('td');
                    gutter.className = 'lh-gutter';
                    gutter.textContent = String(i + 1);
                    const code = document.createElement('td');
                    code.className = 'lh-line';
                    code.textContent = line;      // TEXT node — never parsed as HTML
                    row.appendChild(gutter); row.appendChild(code);
                    body.appendChild(row);
                });
                table.appendChild(body);
                root.appendChild(table);
            }
            // ⌘F content search installs this to scroll to + highlight one line.
            // A no-op when the line is absent (empty file, out-of-range).
            window.lighthouseScrollToLine = function (n) {
                // Clear any prior highlight so repeated in-file jumps show only
                // the current line.
                document.querySelectorAll('tr.lh-hit').forEach(function (r) {
                    r.classList.remove('lh-hit');
                });
                const row = document.getElementById('L' + n);
                if (!row) { return; }
                row.classList.add('lh-hit');
                row.scrollIntoView({ block: 'center' });
            };
            \(debugBlock)
        })();
        </script>
        </body>
        </html>
        """
    }

    /// Hostile fixture reused by the unit test (and any future render gate):
    /// a script-close + injected image handler, plus unicode, that must survive
    /// only inside the base64 payload and render as inert text.
    public static let hostileContent = """
    </script><img src=x onerror=alert(1)>
    <script>window.__pwned=true</script>
    café — ☕ — 汉字 — 😈
    """
}
