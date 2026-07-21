import SwiftUI
import LighthouseAppCore
import LighthouseGit

/// ⌘F content search: `git grep` over the active task's repo with a text/regex
/// toggle and an optional folder scope. Same palette look and keyboard model as
/// the ⌘P finder — ↑/↓ move a highlight that auto-scrolls, ↩ opens the file in
/// the center viewer scrolled to (and highlighting) the matched line. Live but
/// debounced so a keystroke doesn't spawn a grep per character.
struct ContentSearchOverlay: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.theme) private var theme
    @Environment(\.motionEnabled) private var motionEnabled
    let workbench: WorkbenchModel
    /// ⌘F ("find in file") opens pre-scoped to the file in the viewer; ⇧⌘F
    /// ("find in files") opens repo-wide. Either way the scope field stays
    /// editable, so the user can widen or narrow after the fact.
    var scopeToFile = false

    @State private var query = ""
    @State private var folder = ""
    @State private var useRegex = false
    @State private var matches: [GrepMatch] = []
    @State private var error: String?
    @State private var searching = false
    @State private var selected = 0
    @State private var searchTask: Task<Void, Never>?
    /// Bumped on every scheduled search; only the run whose generation still
    /// matches owns the UI state (results + the `searching` indicator), so a
    /// superseded run can neither overwrite fresh results nor leave the spinner
    /// stuck / stomp a newer run's spinner.
    @State private var searchGeneration = 0
    @State private var popped = false
    @FocusState private var focus: Field?

    /// The two keyboard-focusable text fields; ⇥ cycles between them without
    /// ever leaking focus to the terminal behind the overlay.
    private enum Field { case search, folder }

    private static let debounce = Duration.milliseconds(180)

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: 0x06080d, opacity: 0.5)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
            panel
                .frame(width: 680)
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
        .onChange(of: query) { scheduleSearch() }
        .onChange(of: folder) { scheduleSearch() }
        .onChange(of: useRegex) { scheduleSearch() }
        .onAppear {
            // In-file mode pre-fills the scope with the open file's path (a git
            // grep pathspec of one file); repo-wide leaves it empty.
            if scopeToFile, let file = workbench.currentFilePath { folder = file }
            focus = .search
            if motionEnabled {
                withAnimation(.easeOut(duration: 0.16)) { popped = true }
            } else {
                popped = true
            }
        }
        .onDisappear { searchTask?.cancel() }
    }

    @ViewBuilder
    private var panel: some View {
        VStack(spacing: 0) {
            header
            searchField
            folderField
            Divider().overlay(theme.borderSoft)
            content
            Divider().overlay(theme.borderSoft)
            footerHint
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(scopeToFile ? "Find in File" : "Find in Files")
                .font(LHFont.ui(11, .semibold))
                .tracking(0.4)
                .foregroundStyle(theme.faint)
            if scopeToFile, let name = workbench.currentFilePath?.split(separator: "/").last {
                Text("· \(name)")
                    .font(LHFont.meta)
                    .foregroundStyle(theme.dim)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.dim)
            TextField(useRegex ? "Search by regex…" : "Search text in files…", text: $query)
                .textFieldStyle(.plain)
                .font(LHFont.ui(15))
                .foregroundStyle(theme.text)
                .focused($focus, equals: .search)
                .onSubmit { open(selectedMatch()) }
                .modifier(PaletteKeys(
                    onArrow: move, onTab: cycleFocus, onEscape: dismiss))
            regexToggle
            Keycap(text: "esc")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var regexToggle: some View {
        Button { useRegex.toggle() } label: {
            Text(".*")
                .font(LHFont.mono(12, .semibold))
                .foregroundStyle(useRegex ? theme.primaryText : theme.dim)
                .frame(width: 30, height: 22)
                .background(useRegex ? theme.primary : theme.panel3,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(.plain)
        // ⌥⌘R toggles regex from the keyboard (⌘-combo so it fires while a text
        // field has focus); clicking still works.
        .keyboardShortcut("r", modifiers: [.command, .option])
        .help("Toggle regular-expression matching (⌥⌘R)")
    }

    private var folderField: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(theme.dim)
            TextField("Scope: a file or folder path (optional)", text: $folder)
                .textFieldStyle(.plain)
                .font(LHFont.ui(12.5))
                .foregroundStyle(theme.text)
                .focused($focus, equals: .folder)
                .onSubmit { open(selectedMatch()) }
                // Arrows still drive the results from inside the folder field,
                // and ⇥ cycles back to the search field — never to the terminal.
                .modifier(PaletteKeys(
                    onArrow: move, onTab: cycleFocus, onEscape: dismiss))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    /// The keyboard hints, so the whole modal is discoverable without the mouse.
    private var footerHint: some View {
        HStack(spacing: 12) {
            hint("↑↓", "move")
            hint("⇥", "field")
            hint("⌥⌘R", "regex")
            hint("↩", "open")
            hint("esc", "close")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Keycap(text: key)
            Text(label).font(LHFont.metaFaint).foregroundStyle(theme.faint)
        }
    }

    /// ⇥ / ⇧⇥ toggle between the two fields (only two, so either direction is a
    /// toggle) and, critically, are consumed here so Tab can't advance the key
    /// view loop into the terminal.
    private func cycleFocus() {
        focus = (focus == .search) ? .folder : .search
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            message(error, tint: .red)
        } else if query.isEmpty {
            message("Type to search file contents.")
        } else if searching && matches.isEmpty {
            message("Searching…")
        } else if matches.isEmpty {
            message("No matches")
        } else {
            resultsList
        }
    }

    private func message(_ text: String, tint: Color? = nil) -> some View {
        Text(text)
            .font(LHFont.body)
            .foregroundStyle(tint ?? theme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                        row(match, isSelected: index == clamp(selected))
                            .id(match.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 380)
            .onChange(of: selected) {
                let idx = clamp(selected)
                guard matches.indices.contains(idx) else { return }
                withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(matches[idx].id, anchor: .center) }
            }
        }
    }

    private func row(_ match: GrepMatch, isSelected: Bool) -> some View {
        let name = String(match.path.split(separator: "/").last ?? Substring(match.path))
        return Button { open(match) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(LHFont.ui(12.5, .medium))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Text("\(match.path):\(match.line)")
                            .font(LHFont.meta)
                            .foregroundStyle(theme.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(match.text.trimmingCharacters(in: .whitespaces))
                        .font(LHFont.mono(11.5))
                        .foregroundStyle(theme.dim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? theme.border2 : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    // MARK: - Search

    /// Debounced: cancel the pending grep and start a new one after a short
    /// pause, so holding a key doesn't fire a grep per character.
    private func scheduleSearch() {
        searchTask?.cancel()
        // Clear the spinner at schedule time (we're debouncing, not yet
        // grepping); the debounced run flips it back on. Belt-and-braces with
        // the generation guard so the indicator can never linger.
        searching = false
        searchGeneration += 1
        let generation = searchGeneration
        let pattern = query
        let scope = folder
        let regex = useRegex
        searchTask = Task {
            try? await Task.sleep(for: Self.debounce)
            if Task.isCancelled { return }
            await runSearch(pattern: pattern, folder: scope, regex: regex, generation: generation)
        }
    }

    private func runSearch(pattern: String, folder: String, regex: Bool, generation: Int) async {
        guard !pattern.isEmpty else {
            matches = []; error = nil; searching = false
            return
        }
        searching = true
        do {
            let found = try await workbench.contentSearch(
                pattern: pattern, regex: regex, folder: folder.isEmpty ? nil : folder)
            guard generation == searchGeneration else { return }  // superseded
            matches = found
            error = nil
            selected = 0
        } catch {
            guard generation == searchGeneration else { return }
            matches = []
            self.error = Self.describe(error)
        }
        // Only the latest search clears the spinner; a superseded run returned
        // above without touching it, and the latest run always reaches here.
        if generation == searchGeneration { searching = false }
    }

    /// git's own reason (e.g. an unbalanced regex, a missing folder), trimmed to
    /// one line — never a fabricated message.
    private static func describe(_ error: any Error) -> String {
        if case let GitClientError.commandFailed(failure) = error {
            let reason = failure.stderr
                .split(separator: "\n").first.map(String.init) ?? "search failed"
            return reason.replacingOccurrences(of: "fatal: ", with: "")
        }
        return String(describing: error)
    }

    // MARK: - Selection & actions

    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selected = clamp(selected + delta)
    }

    private func selectedMatch() -> GrepMatch? {
        guard !matches.isEmpty else { return nil }
        return matches[clamp(selected)]
    }

    private func clamp(_ index: Int) -> Int {
        guard !matches.isEmpty else { return 0 }
        return min(max(index, 0), matches.count - 1)
    }

    /// Open the file in the center viewer, scrolled to and highlighting the
    /// matched line, then close the palette. A nil pick is a no-op.
    private func open(_ match: GrepMatch?) {
        guard let match else { return }
        Task { await workbench.selectFile(match.path, line: match.line) }
        dismiss()
    }

    private func dismiss() {
        searchTask?.cancel()
        runtime.contentSearchPresented = false
    }
}

/// Shared key handling for the search modal's text fields: ↑/↓ drive the result
/// selection, ⇥/⇧⇥ cycle the fields, and esc closes — every one consumed
/// (`.handled`) so nothing (Tab especially) escapes to the terminal behind the
/// overlay. Attached to BOTH fields so the bindings work wherever focus sits.
private struct PaletteKeys: ViewModifier {
    let onArrow: (Int) -> Void
    let onTab: () -> Void
    let onEscape: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.downArrow) { onArrow(1); return .handled }
            .onKeyPress(.upArrow) { onArrow(-1); return .handled }
            .onKeyPress(keys: [.tab]) { _ in onTab(); return .handled }
            .onExitCommand { onEscape() }
    }
}
