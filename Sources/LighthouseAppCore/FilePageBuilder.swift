import Foundation

/// Renders a repo file for the content viewer's locked WKWebView: line-numbered
/// source (syntax-highlighted when the language is known) and, for markdown, a
/// rendered view with a Rendered/Source toggle.
///
/// Same discipline as DiffPageBuilder (spec §8): file content is untrusted repo
/// content, so no byte of it — nor the filename — ever appears raw in the markup.
/// Both are base64-embedded and decoded in-page into TEXT nodes (source view) or
/// handed to the vendored parsers, whose output is reduced to an allowlist of
/// tags and attributes before it is attached. Markdown runs with raw HTML
/// disabled, images become a text placeholder, and links are inert.
///
/// CSP: `default-src 'none'` always. A plain page has no assets and no
/// `script-src 'self'`; a page that highlights or renders markdown adds `'self'`
/// so the vendored scripts in the render directory (Resources/viewer) can load.
/// Nothing loads over the network either way.
public enum FilePageBuilder {

    /// Where the vendored assets live in the app bundle, and what the page
    /// references from the render directory. `SHA256SUMS` beside them is the
    /// supply-chain source of truth.
    public static let assetSubdirectory = "Resources/viewer"
    public static let highlightScript = "highlight.min.js"
    public static let markdownScript = "markdown-it.min.js"
    public static let lightTheme = "hljs-light.min.css"
    public static let darkTheme = "hljs-dark.min.css"
    public static let assets = [highlightScript, markdownScript, lightTheme, darkTheme]

    public static func page(
        content: String, filename: String, rendering: FileRendering = .plain,
        debugChecks: Bool = false
    ) -> String {
        let payload = Data(content.utf8).base64EncodedString()
        let namePayload = Data(filename.utf8).base64EncodedString()
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        let language = rendering.language.flatMap { FileRendering.isSafeLanguageToken($0) ? $0 : nil } ?? ""
        let withAssets = rendering.needsAssets
        let scriptSources = withAssets ? "'self' 'nonce-\(nonce)'" : "'nonce-\(nonce)'"
        let styleSources = withAssets ? "'self' 'unsafe-inline'" : "'unsafe-inline'"
        let assetTags = !withAssets ? "" : """
            <link rel="stylesheet" href="\(lightTheme)" media="(prefers-color-scheme: light)">
            <link rel="stylesheet" href="\(darkTheme)" media="(prefers-color-scheme: dark)">
            <script src="\(highlightScript)"></script>
            \(rendering.markdown ? "<script src=\"\(markdownScript)\"></script>" : "")
            """
        let debugBlock = debugChecks ? Self.debugScript : ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src \(scriptSources); style-src \(styleSources);">
        \(assetTags)
        <style>\(Self.styles)</style>
        </head>
        <body>
        <div id="bar"><h2 id="title"></h2><span id="modes"></span></div>
        <div id="file"></div>
        <script nonce="\(nonce)">
        (function () {
            const NAME = "\(namePayload)";
            const PAYLOAD = "\(payload)";
            const LANGUAGE = "\(language)";
            const MARKDOWN = \(rendering.markdown ? "true" : "false");
            \(Self.bootstrap)
            \(debugBlock)
        })();
        </script>
        </body>
        </html>
        """
    }

    private static let styles = #"""

        body { margin: 0; font-family: -apple-system, sans-serif; font-size: 12px; }
        #bar { display: flex; align-items: center; justify-content: space-between;
            border-bottom: 1px solid #ccc; }
        #title { font-size: 13px; padding: 8px 10px; margin: 0; }
        #modes { padding-right: 10px; }
        #modes button { font: inherit; padding: 2px 10px; border: 1px solid rgba(128,128,128,0.5);
            background: transparent; color: inherit; cursor: pointer; }
        #modes button:first-child { border-radius: 5px 0 0 5px; }
        #modes button:last-child { border-radius: 0 5px 5px 0; border-left: 0; }
        #modes button.on { background: rgba(128,128,128,0.25); }
        table.lh-code { border-collapse: collapse; width: 100%;
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
        td.lh-gutter { text-align: right; padding: 0 10px; width: 1%; white-space: nowrap;
            color: #999; background: rgba(128,128,128,0.08); user-select: none;
            border-right: 1px solid rgba(128,128,128,0.25); }
        td.lh-line { padding: 0 10px; white-space: pre; }
        /* ⌘F jump target highlight. */
        tr.lh-hit td { background: rgba(255, 213, 0, 0.22); }
        #empty { color: #888; padding: 24px; text-align: center; }
        #rendered { max-width: 820px; margin: 0 auto; padding: 16px 24px 48px;
            font-size: 14px; line-height: 1.55; overflow-wrap: anywhere; }
        #rendered h1, #rendered h2 { border-bottom: 1px solid rgba(128,128,128,0.3); padding-bottom: 0.3em; }
        #rendered code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px;
            background: rgba(128,128,128,0.15); padding: 1px 4px; border-radius: 4px; }
        #rendered pre { background: rgba(128,128,128,0.12); padding: 10px 12px; border-radius: 6px;
            overflow-x: auto; }
        #rendered pre code { background: none; padding: 0; }
        #rendered table { border-collapse: collapse; }
        #rendered th, #rendered td { border: 1px solid rgba(128,128,128,0.35); padding: 4px 10px; }
        #rendered blockquote { margin: 0; padding: 0 14px; border-left: 3px solid rgba(128,128,128,0.45);
            color: #666; }
        #rendered hr { border: 0; border-top: 1px solid rgba(128,128,128,0.35); }
        .lh-link { color: #0969da; text-decoration: underline dotted; }
        .lh-missing { color: #888; font-style: italic; }
        @media (prefers-color-scheme: dark) {
            body { background:#1e1e1e; color:#ddd; }
            tr.lh-hit td { background: rgba(255, 213, 0, 0.16); }
            #rendered blockquote { color: #aaa; }
            .lh-link { color: #58a6ff; }
        }
    """#

    /// The in-page program. Everything it renders from the file goes through text
    /// nodes or the allowlist in `clean`; nothing here evaluates file content.
    private static let bootstrap = #"""
    const dec = b => new TextDecoder().decode(Uint8Array.from(atob(b), c => c.charCodeAt(0)));
            document.getElementById('title').textContent = dec(NAME);
            const text = dec(PAYLOAD);
            const root = document.getElementById('file');
            const hasHighlighter = typeof hljs !== 'undefined';
            const hasMarkdown = typeof markdownit !== 'undefined';
            const source = document.createElement('div');
            source.id = 'source';
            const rendered = document.createElement('div');
            rendered.id = 'rendered';
            rendered.style.display = 'none';

            // Split preserving a trailing newline's empty last line only if the
            // file did not end with one (avoids a phantom blank row).
            const plain = text.split("\n");
            if (plain.length > 1 && plain[plain.length - 1] === "") { plain.pop(); }

            // highlight.js output (escaped text + <span class>) cut into one DOM
            // fragment per source line, re-opening any span a newline cuts across.
            // Null when the language is unknown or the cut disagrees with the
            // plain split — the caller then shows plain text.
            function highlightedLines() {
                if (!LANGUAGE || !hasHighlighter || !hljs.getLanguage(LANGUAGE)) { return null; }
                try {
                    const html = hljs.highlight(text, { language: LANGUAGE, ignoreIllegals: true }).value;
                    const tpl = document.createElement('template');
                    tpl.innerHTML = html;
                    const lines = [];
                    const open = [];
                    let chain = [];
                    function newLine() {
                        const fragment = document.createDocumentFragment();
                        lines.push(fragment);
                        chain = [fragment];
                        open.forEach(function (cls) {
                            const el = document.createElement('span');
                            el.className = cls;
                            chain[chain.length - 1].appendChild(el);
                            chain.push(el);
                        });
                    }
                    function walk(node) {
                        node.childNodes.forEach(function (child) {
                            if (child.nodeType === 3) {
                                child.nodeValue.split("\n").forEach(function (part, i) {
                                    if (i > 0) { newLine(); }
                                    if (part) { chain[chain.length - 1].appendChild(document.createTextNode(part)); }
                                });
                            } else if (child.nodeType === 1 && child.tagName === 'SPAN') {
                                const cls = /^[A-Za-z0-9_ -]*$/.test(child.className) ? child.className : '';
                                const el = document.createElement('span');
                                el.className = cls;
                                chain[chain.length - 1].appendChild(el);
                                chain.push(el);
                                open.push(cls);
                                walk(child);
                                open.pop();
                                chain.pop();
                            } else {
                                chain[chain.length - 1].appendChild(document.createTextNode(child.textContent));
                            }
                        });
                    }
                    newLine();
                    walk(tpl.content);
                    if (lines.length > 1 && !lines[lines.length - 1].hasChildNodes()) { lines.pop(); }
                    return lines.length === plain.length ? lines : null;
                } catch (e) { return null; }
            }

            function buildSource() {
                const highlighted = highlightedLines();
                const table = document.createElement('table');
                table.className = 'lh-code';
                const body = document.createElement('tbody');
                plain.forEach(function (line, i) {
                    const row = document.createElement('tr');
                    row.id = 'L' + (i + 1);       // ⌘F jump anchor (1-based)
                    const gutter = document.createElement('td');
                    gutter.className = 'lh-gutter';
                    gutter.textContent = String(i + 1);
                    const code = document.createElement('td');
                    code.className = 'lh-line';
                    if (highlighted) { code.appendChild(highlighted[i]); }
                    else { code.textContent = line; }   // TEXT node — never parsed as HTML
                    row.appendChild(gutter); row.appendChild(code);
                    body.appendChild(row);
                });
                table.appendChild(body);
                source.appendChild(table);
            }

            // The only things rendered markdown may contain. Anything else becomes
            // its text; images become a placeholder (the CSP would block them
            // anyway); links lose their href (navigation is denied natively too)
            // and keep it as a tooltip.
            const TAGS = new Set(['P','H1','H2','H3','H4','H5','H6','UL','OL','LI','BLOCKQUOTE','PRE',
                'CODE','EM','STRONG','S','DEL','A','HR','BR','TABLE','THEAD','TBODY','TR','TH','TD','SPAN']);
            function clean(node) {
                Array.from(node.childNodes).forEach(function (child) {
                    if (child.nodeType === 3) { return; }
                    if (child.nodeType !== 1) { child.remove(); return; }
                    if (child.tagName === 'IMG') {
                        const note = document.createElement('span');
                        note.className = 'lh-missing';
                        note.textContent = '[image: ' + (child.getAttribute('alt') || '') + ']';
                        child.replaceWith(note);
                        return;
                    }
                    if (!TAGS.has(child.tagName)) {
                        child.replaceWith(document.createTextNode(child.textContent));
                        return;
                    }
                    const href = child.tagName === 'A' ? child.getAttribute('href') : null;
                    Array.from(child.attributes).forEach(function (a) {
                        const ok = (a.name === 'class' && /^[A-Za-z0-9_ -]*$/.test(a.value))
                            || (a.name === 'start' && /^[0-9]{1,6}$/.test(a.value))
                            || (a.name === 'style' && /^text-align:(left|right|center)$/.test(a.value));
                        if (!ok) { child.removeAttribute(a.name); }
                    });
                    if (child.tagName === 'A') {
                        child.className = 'lh-link';
                        if (href) { child.title = href; }
                    }
                    clean(child);
                });
            }

            function buildRendered() {
                const md = window.markdownit({
                    html: false, linkify: false, breaks: false,
                    highlight: function (code, lang) {
                        if (hasHighlighter && lang && hljs.getLanguage(lang)) {
                            try { return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value; }
                            catch (e) { /* fall through to markdown-it's escaping */ }
                        }
                        return '';
                    },
                });
                const tpl = document.createElement('template');
                tpl.innerHTML = md.render(text);
                clean(tpl.content);
                rendered.appendChild(tpl.content);
            }

            function setMode(mode) {
                rendered.style.display = mode === 'rendered' ? '' : 'none';
                source.style.display = mode === 'source' ? '' : 'none';
                document.querySelectorAll('#modes button').forEach(function (b) {
                    b.className = b.dataset.mode === mode ? 'on' : '';
                });
            }

            if (text.length === 0) {
                root.innerHTML = '<div id="empty">Empty file.</div>';
            } else {
                buildSource();
                root.appendChild(rendered);
                root.appendChild(source);
                let mode = 'source';
                if (MARKDOWN && hasMarkdown) {
                    try { buildRendered(); mode = 'rendered'; } catch (e) { rendered.textContent = ''; }
                }
                if (mode === 'rendered') {
                    const modes = document.getElementById('modes');
                    [['rendered', 'Rendered'], ['source', 'Source']].forEach(function (pair) {
                        const button = document.createElement('button');
                        button.dataset.mode = pair[0];
                        button.textContent = pair[1];
                        button.addEventListener('click', function () { setMode(pair[0]); });
                        modes.appendChild(button);
                    });
                }
                setMode(mode);
            }
            // ⌘F content search installs this to scroll to + highlight one line.
            // A no-op when the line is absent (empty file, out-of-range). Line
            // anchors exist only in the source view, so it switches to it first.
            window.lighthouseScrollToLine = function (n) {
                document.querySelectorAll('tr.lh-hit').forEach(function (r) {
                    r.classList.remove('lh-hit');
                });
                const row = document.getElementById('L' + n);
                if (!row) { return; }
                if (source.style.display === 'none') { setMode('source'); }
                row.classList.add('lh-hit');
                row.scrollIntoView({ block: 'center' });
            };
    """#

    /// Self-check the runtime gate (LIGHTHOUSE_DEBUG_FILERENDER) injects: the page
    /// inspects its own DOM and posts the verdict to the receive-only handler.
    private static let debugScript = """
        try {
            const root = document.getElementById('file');
            const result = {
                scripts: root.querySelectorAll('script').length,
                handlers: root.querySelectorAll('[onerror],[onclick],[onload]').length,
                imgs: root.querySelectorAll('img').length,
                pwned: window.__pwned === true,
                hostileTextPresent: root.textContent.includes("<img src=x onerror=alert(1)>"),
                lines: root.querySelectorAll('.lh-line').length,
                links: root.querySelectorAll('a[href]').length,
                badTags: root.querySelectorAll('iframe,object,embed,form,style,link,meta,base,svg,video,audio').length,
                highlighted: root.querySelectorAll('[class^="hljs-"]').length,
                rendered: document.getElementById('rendered') !== null
                    && document.getElementById('rendered').childNodes.length > 0,
            };
            window.webkit?.messageHandlers?.diffDebug?.postMessage(JSON.stringify(result));
        } catch (e) {
            window.webkit?.messageHandlers?.diffDebug?.postMessage('{"error":"'+String(e).replace(/"/g,"'")+'"}');
        }
    """

    /// Hostile fixture reused by the unit test (and any future render gate):
    /// a script-close + injected image handler, plus unicode, that must survive
    /// only inside the base64 payload and render as inert text.
    public static let hostileContent = """
    </script><img src=x onerror=alert(1)>
    <script>window.__pwned=true</script>
    café — ☕ — 汉字 — 😈
    """

    /// Markdown flavour of the hostile fixture: the same executable-looking text,
    /// plus the constructs the renderer must neutralize (script-scheme link,
    /// remote image, raw HTML, a fenced block with a hostile language tag).
    public static let hostileMarkdown = hostileContent + """


    [click](javascript:window.__pwned=true) ![pixel](https://evil.example/p.png)
    <iframe src="https://evil.example"></iframe> <b onclick="window.__pwned=true">bold</b>

    ```"><img src=x onerror=alert(1)>
    let x = 1
    ```
    """
}
