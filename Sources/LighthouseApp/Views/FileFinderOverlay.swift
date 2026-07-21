import SwiftUI
import LighthouseAppCore

/// ⌘P quick-open: fuzzy file finder over the active task's repo. Mirrors the
/// Cmd+K SwitcherOverlay's palette look; ranking is `FileFinder` (pure, tested).
/// Picking a row loads that file into the center viewer via the workbench —
/// exactly what a Files-navigator tap does, just reached by typing a name.
///
/// Fully keyboard-driven: focus stays in the field, ↑/↓ move the highlight
/// (which auto-scrolls into view) and ↩ opens it, so the palette never needs the
/// mouse. Clicking a row still works.
struct FileFinderOverlay: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    @Environment(\.motionEnabled) private var motionEnabled
    let workbench: WorkbenchModel

    @State private var query = ""
    @State private var paths: [String] = []
    @State private var loaded = false
    @State private var popped = false
    /// Index of the highlighted result; clamped against the live result count at
    /// every use, so a shrinking result set can never point out of bounds.
    @State private var selected = 0
    @FocusState private var fieldFocused: Bool

    private static let resultLimit = 100

    var body: some View {
        let results = FileFinder.rank(query: query, paths: paths, limit: Self.resultLimit)
        ZStack(alignment: .top) {
            Color(hex: 0x06080d, opacity: 0.5)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
            panel(results)
                .frame(width: 620)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.palette))
                .background(theme.panel.opacity(0.92),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.palette))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.palette)
                    .strokeBorder(theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                .scaleEffect(motionEnabled ? (popped ? 1 : 0.96) : 1)
                .opacity(motionEnabled ? (popped ? 1 : 0) : 1)
                .padding(.top, 90)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A new query re-ranks the list, so the highlight returns to the top.
        .onChange(of: query) { selected = 0 }
        .onAppear {
            fieldFocused = true
            if motionEnabled {
                withAnimation(.easeOut(duration: 0.16)) { popped = true }
            } else {
                popped = true
            }
            Task {
                paths = await workbench.fileFinderPaths()
                loaded = true
            }
        }
    }

    @ViewBuilder
    private func panel(_ results: [String]) -> some View {
        VStack(spacing: 0) {
            searchField(results)
            Divider().overlay(theme.borderSoft)
            if !loaded {
                message("Loading files…")
            } else if results.isEmpty {
                message(paths.isEmpty ? "No files in this repo" : "No matching files")
            } else {
                resultsList(results)
            }
        }
    }

    private func searchField(_ results: [String]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.dim)
            TextField("Find file by name…", text: $query)
                .textFieldStyle(.plain)
                .font(LHFont.ui(15))
                .foregroundStyle(theme.text)
                .focused($fieldFocused)
                .onSubmit { open(selectedPath(in: results)) }
                .onExitCommand { dismiss() }
                // Arrow keys move the highlight while the field keeps focus and
                // keeps filtering; .handled stops the caret from jumping instead.
                .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
                .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
            Keycap(text: "esc")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(LHFont.body)
            .foregroundStyle(theme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    private func resultsList(_ results: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element) { index, path in
                        row(path, isSelected: index == clamp(selected, results.count))
                            .id(path)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 360)
            // Keep the highlighted row visible as ↑/↓ walk past the fold.
            .onChange(of: selected) {
                let idx = clamp(selected, results.count)
                guard results.indices.contains(idx) else { return }
                withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(results[idx], anchor: .center) }
            }
        }
    }

    private func row(_ path: String, isSelected: Bool) -> some View {
        let name = String(path.split(separator: "/").last ?? Substring(path))
        let dir = path.dropLast(name.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Button { open(path) } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(isSelected ? theme.primary : theme.dim)
                Text(name)
                    .font(LHFont.ui(13.5, .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                if !dir.isEmpty {
                    Text(dir)
                        .font(LHFont.meta)
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? theme.border2 : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    // MARK: - Selection

    /// Moves the highlight by `delta`, clamped to the current results (no wrap).
    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selected = clamp(selected + delta, count)
    }

    private func selectedPath(in results: [String]) -> String? {
        guard !results.isEmpty else { return nil }
        return results[clamp(selected, results.count)]
    }

    private func clamp(_ index: Int, _ count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    // MARK: - Actions

    /// Load the picked file into the center viewer (same path a Files-navigator
    /// tap takes), then close the palette. A nil pick (empty results) is a no-op.
    private func open(_ path: String?) {
        guard let path else { return }
        Task { await workbench.selectFile(path) }
        dismiss()
    }

    private func dismiss() {
        runtime.fileFinderPresented = false
    }
}
