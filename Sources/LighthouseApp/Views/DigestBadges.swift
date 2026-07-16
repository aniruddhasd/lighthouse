import SwiftUI
import LighthouseAppCore
import LighthouseGit

/// Shared, honest renderers for the Phase-4 digest fields. Each renders NOTHING
/// when its data is absent — a nil field is a graceful blank, never a `0`,
/// `—%`, or placeholder implying data. A DiffStat of `.zero` is a KNOWN zero and
/// renders real `0`s; the caller passes nil (not `.zero`) for "unknown".

/// Model chip: a blue dot + the model id (handoff §1 "model chip"). The id is
/// already sanitised by `TranscriptReader`; rendered as inert `Text`.
struct ModelChip: View {
    @Environment(\.theme) private var theme
    let model: String
    var font: Font = LHFont.mono(11)

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(theme.modelDot).frame(width: 6, height: 6)
            Text(model).font(font).foregroundStyle(theme.dim).lineLimit(1)
        }
    }
}

/// `+{add}` (green) · `−{del}` (red) · `{files} file(s)` — deterministic git
/// counts. All three are one reading, so they render together or not at all.
struct DiffMetrics: View {
    @Environment(\.theme) private var theme
    let stat: DiffStat
    var font: Font = LHFont.mono(11)

    var body: some View {
        HStack(spacing: 8) {
            Text("+\(stat.added)").font(font).foregroundStyle(theme.addedTextChrome)
            // U+2212 MINUS SIGN, matching the handoff's "−del".
            Text("\u{2212}\(stat.deleted)").font(font).foregroundStyle(theme.removedTextChrome)
            Text("\(stat.filesChanged) file\(stat.filesChanged == 1 ? "" : "s")")
                .font(font).foregroundStyle(theme.faint)
        }
    }
}

/// The context-window meter (spec §5.2 / §5.3) — a small gradient bar + the
/// estimated percent. Shown ONLY when an honest estimate exists (built by
/// `TranscriptReader` from real token usage against a known window). Framed as
/// an estimate: the tooltip states used/window tokens.
struct ContextMeter: View {
    @Environment(\.theme) private var theme
    let context: ContextEstimate
    /// Compact (footer/header) vs. labelled (Summary "Context" card).
    var showPercentLabel: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.border2)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [theme.contextMeterStart, theme.contextMeterEnd],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, geo.size.width * context.fraction))
                }
            }
            .frame(width: 46, height: 5)
            if showPercentLabel {
                Text("~\(context.percent)%")
                    .font(LHFont.mono(11)).foregroundStyle(theme.dim)
            }
        }
        .help("Estimated context used: ~\(context.usedTokens) of \(context.windowTokens) tokens")
    }
}
