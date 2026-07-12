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
`Sources/LighthouseApp/Resources/diff2html/`:

```
a2110a09cee157bd5466da77be02107ac81a0baa2bc1f3fe81aac8183314598e  diff2html.min.js
d3ecc0e9b2b1e5c8466c19de29bed052fd0863475d25829ecc858446efded372  diff2html.min.css
```

The base bundle is used (not `diff2html-ui`, which pulls highlight.js) —
no syntax highlighting in v1, no extra attack surface. To upgrade: verify
the new version on the npm registry, re-download, update these checksums.

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
