# Third-party notices

Lighthouse is MIT-licensed (see `LICENSE`). It builds on, or bundles, the
components below, each under its own license. Versions are the ones pinned in this
repository (`Package.resolved`, `Scripts/pinned-revisions.txt`, and the
`SHA256SUMS` files next to the vendored assets).

| Component | Version | License | Where |
|---|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.14.0 | MIT | Swift package dependency (the terminal) |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 | Resolved as a dependency of SwiftTerm |
| [diff2html](https://github.com/rtfpessoa/diff2html) | 3.4.56 | MIT | `Sources/LighthouseApp/Resources/diff2html/` (license: `LICENSE-diff2html.txt`) |
| [highlight.js](https://highlightjs.org) | 11.12.0 | BSD-3-Clause | `Sources/LighthouseApp/Resources/viewer/` (license: `LICENSE-highlightjs.txt`) |
| [markdown-it](https://github.com/markdown-it/markdown-it) | 15.0.3 | MIT | `Sources/LighthouseApp/Resources/viewer/` (license: `LICENSE-markdown-it.txt`) |
| [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) | bundled files | SIL OFL 1.1 | `Sources/LighthouseApp/Resources/fonts/` (license: `OFL.txt`) |

The full license text of each vendored asset sits beside it. SwiftTerm and
swift-argument-parser are fetched by Swift Package Manager at build time and are
not committed here; their licenses ship in their own repositories.
