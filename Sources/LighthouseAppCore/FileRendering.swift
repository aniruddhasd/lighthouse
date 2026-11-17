import Foundation

/// How the content viewer should present one text file. A pure decision from the
/// filename and size, so it is unit-tested without WebKit. The page builder turns
/// it into markup; the vendored highlighter and markdown assets do the drawing.
public struct FileRendering: Equatable, Sendable {
    /// highlight.js language name, from the closed table below (nil → plain text).
    public let language: String?
    /// Offer a rendered view (default) alongside the source.
    public let markdown: Bool

    public init(language: String?, markdown: Bool) {
        self.language = language
        self.markdown = markdown
    }

    public static let plain = FileRendering(language: nil, markdown: false)

    /// True when the page needs the vendored viewer assets (and so a CSP that
    /// permits same-directory scripts).
    public var needsAssets: Bool { language != nil || markdown }

    /// Beyond these the highlighter / markdown parser is skipped and the file is
    /// shown as plain text: both run synchronously in the page.
    public static let maxHighlightBytes = 400_000
    public static let maxHighlightLines = 8_000

    public static func forFile(named filename: String, content: String) -> FileRendering {
        let bytes = content.utf8.count
        guard bytes <= maxHighlightBytes else { return .plain }
        let name = (filename as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension

        if markdownExtensions.contains(ext) {
            return FileRendering(language: "markdown", markdown: true)
        }
        // Counting lines costs a pass over the content; only pay it for a file
        // that would actually be highlighted.
        guard let language = languageByName[name] ?? languageByExtension[ext] else { return .plain }
        let lines = content.utf8.reduce(into: 1) { if $1 == 0x0A { $0 += 1 } }
        guard lines <= maxHighlightLines else { return .plain }
        return FileRendering(language: language, markdown: false)
    }

    /// Only names present in the vendored highlight.js bundle (the "common" set,
    /// verified against `hljs.listLanguages()` of 11.12.0). A value outside
    /// `isSafeLanguageToken` is never interpolated into a page.
    static let languageByExtension: [String: String] = [
        "swift": "swift", "py": "python", "pyi": "python", "js": "javascript", "mjs": "javascript",
        "cjs": "javascript", "jsx": "javascript", "ts": "typescript", "tsx": "typescript",
        "json": "json", "jsonc": "json", "yml": "yaml", "yaml": "yaml", "toml": "ini", "ini": "ini",
        "cfg": "ini", "sh": "bash", "bash": "bash", "zsh": "bash", "css": "css", "scss": "scss",
        "less": "less", "html": "xml", "htm": "xml", "xml": "xml", "plist": "xml", "svg": "xml",
        "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "m": "objectivec",
        "mm": "objectivec", "cs": "csharp", "java": "java", "kt": "kotlin", "kts": "kotlin",
        "go": "go", "rs": "rust", "rb": "ruby", "php": "php", "pl": "perl", "lua": "lua", "r": "r",
        "sql": "sql", "graphql": "graphql", "gql": "graphql", "diff": "diff", "patch": "diff",
        "mk": "makefile", "wasm": "wasm",
    ]

    static let languageByName: [String: String] = ["makefile": "makefile", "gnumakefile": "makefile"]

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    /// Lowercase letters and digits only: what a highlight.js language name in
    /// our table looks like, and nothing that could break out of a JS string.
    static func isSafeLanguageToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 32
            && token.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }
}
