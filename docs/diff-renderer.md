# Diff renderer — choice, version, security posture

Resolves the spec §9 open item ("diff renderer library choice inside
WKWebView"). Decision date 2026-07-12.

## Choice: diff2html 3.4.56

| Criterion | diff2html | @git-diff-view (alternative considered) |
|---|---|---|
| Input | raw `git diff` text → unified or side-by-side HTML (purpose-built) | parses git diffs, but rendering targets React/Vue components |
| Maintenance | 3.4.56 published 2026-01-31 (npm registry, verified) | 0.1.6 published 2026-06-21 — active but pre-1.0 |
| License | MIT | MIT |
| Offline bundling | standalone UMD browser bundle + one CSS file, ~95 KB total, zero runtime network references (grep-verified: no http(s)/fetch/XHR in the minified bundle) | no standalone browser bundle |

Monaco's diff editor was dismissed without deep comparison: multi-megabyte,
editor-oriented, wildly over-scoped for a read-only review pane.

## Vendored assets (pinned, committed)

From `cdn.jsdelivr.net/npm/diff2html@3.4.56/bundles/`, committed at
`Sources/LighthouseApp/Resources/diff2html/`.

The canonical sha256 checksums live in
`Sources/LighthouseApp/Resources/diff2html/SHA256SUMS` — the single source of
truth, asserted on every build by `Scripts/verify-vendored-assets.sh` (run
from `make-app.sh` and `smoke-run.sh`). The bundled JetBrains Mono fonts
(`Resources/fonts/`) are checked the same way against their own `SHA256SUMS`. They are deliberately NOT duplicated
here; read that file for the exact hashes.

The base bundle is used (not `diff2html-ui`, which pulls highlight.js) —
no syntax highlighting in v1, no extra attack surface. To upgrade: verify
the new version on the npm registry, re-download, and update `SHA256SUMS`.

## Dependency pins (supply-chain lock)

`swift build --force-resolved-versions` builds only from `Package.resolved`
and errors on manifest/lockfile disagreement (no silent re-resolution).
Beyond that, `Scripts/verify-pins.sh` asserts the resolved revisions against
the canonical known-good values in `Scripts/pinned-revisions.txt`. A drifted
pin fails the build and points at the upgrade ritual (`/dep-audit` →
review the upstream diff → re-pin in `Package.swift` → update
`pinned-revisions.txt`) — never blind acceptance.

## Security posture (spec §8 — diff content is untrusted repo content)

- **No raw bytes in HTML:** the whole patch is embedded base64 inside the
  page and decoded in JS; diff2html emits file content as DOM text nodes.
- **CSP:** `default-src 'none'; script-src 'self' 'nonce-<random>';
  style-src 'self' 'unsafe-inline'; img-src data:` — every network source
  forbidden; only the vendored bundle and the per-page-nonce bootstrap run.
- **WKWebView lockdown:** navigation delegate denies everything except
  file: URLs inside the render directory; the only JS bridge is the
  receive-only `diffDebug` handler used by the gate.
- **Caps:** per-file patch sections above 500 KB render as a one-line
  notice (diff2html builds a DOM node per line; 500 KB keeps generated
  code visible while bounding the DOM).
- **Proof:** unit tests assert hostile content never appears raw in the
  page source; the `DIFFRENDER` gate (Scripts/smoke-run.sh,
  `LIGHTHOUSE_DEBUG_DIFFRENDER=1`) renders a hostile fixture (script tags,
  event-handler attributes, nonce theft) through the real
  builder→assets→WKWebView pipeline and asserts from the live DOM:
  0 script tags, 0 surviving event handlers, `window.__pwned` unset, and
  the attack strings present as visible TEXT.

## Live-diff semantics (spec §4 contract updated)

`git diff <base>...HEAD` misses uncommitted work — most of what live review
is for. The pane renders `git diff --merge-base <base> --` (working tree vs
the merge base of base and HEAD; doc- and live-verified to cover committed +
staged + unstaged while excluding base-side commits), plus untracked files
rendered as added-file patches via `git diff --no-index -- /dev/null <path>`
(exit 1 = differences, per --exit-code semantics) — agents write new files
without staging them, so hiding untracked files would hide most in-flight
work. Untracked files over the cap are stubbed by size before reading.

## Review scopes (added after this doc's first draft)

The Changes tab offers two scopes: **vs base** (the merge-base diff above) and
**uncommitted** (`GitClient.uncommittedDiff` — working tree vs its own HEAD).
The "vs base" branch defaults to the repo's registered base branch and can be
overridden per task and workspace from the Summary tab
(`Workspace.baseOverride`). Diff files render collapsible, and the file
viewer (`FilePageBuilder`) uses the same WKWebView lockdown with a stricter
CSP (`default-src 'none'; script-src 'nonce-…'; style-src 'unsafe-inline'`).

## File viewer assets (syntax highlighting + markdown)

The content viewer's file page (`FilePageBuilder`) vendors two more libraries,
committed at `Sources/LighthouseApp/Resources/viewer/` and checked by
`Scripts/verify-vendored-assets.sh` against that directory's `SHA256SUMS`
(run from `make-app.sh` and `smoke-run.sh`). Added 2026-10-26.

| Asset | Source (npm, latest stable verified that day) | License |
|---|---|---|
| `highlight.min.js`, `hljs-light.min.css`, `hljs-dark.min.css` | `@highlightjs/cdn-assets@11.12.0` (common-languages build; `styles/github`, `styles/github-dark`) | BSD-3-Clause |
| `markdown-it.min.js` | `markdown-it@15.0.3`, `dist/browser/markdown-it.umd.min.js` | MIT |

Both bundles were grep-checked: no `http(s)` references beyond two doc URLs in a
highlight.js comment, no `fetch`/`XMLHttpRequest`/`eval`/`new Function`.

Posture: file content stays base64 → in-page. Code is highlighted by
highlight.js (output is escaped text plus `<span class>`, re-cut into per-line
DOM). Markdown runs with `html: false`; its output is reduced to an allowlist of
tags/attributes, images become a text placeholder and links lose their `href`
(the native navigation delegate denies non-file URLs regardless). The CSP stays
`default-src 'none'`; only a page that highlights or renders markdown adds
`'self'` so the scripts in the render directory can load. Files over
`FileRendering.maxHighlightBytes`/`maxHighlightLines` are shown as plain text.

Proof: unit tests (`FileRenderingTests`) pin the choice and page shape; the
FILERENDER gate in `smoke-run.sh` renders hostile plain, code and markdown
fixtures in the real WKWebView and asserts no script/img/handler/link/forbidden
element survives and that highlighting and rendering actually ran. A mutation
check (sanitizer disabled → the gate's `imgs` count went 0→1) showed it can fail.
Not covered: languages outside the common set stay plain; links are not
clickable (an external-open bridge is out of scope).
