import SwiftUI

/// Which half of the editor is showing. The Mac app calls these Edit and
/// Preview; on iOS the owner asked for Edit / View.
enum DocumentMode: Hashable {
    case view, edit
}

/// One document, editable or rendered. Covers a library row and a bound-folder
/// file; the store knows which route saves it.
///
/// The buffer lives in `DocumentEditorStore`, not in either subview, so
/// flipping the mode switch cannot lose unsaved typing — the toggle only
/// swaps which view reads that buffer. It also flushes the pending autosave
/// debounce so the backend is current the moment you start reading.
struct DocumentEditorView: View {
    @State private var store: DocumentEditorStore
    @State private var mode: DocumentMode
    @FocusState private var editorFocused: Bool
    @State private var jumpTo: Int?
    private let fallbackTitle: String
    private var outline: [MDSection] { MDSection.parse(store.text).filter { $0.level > 0 } }

    init(api: JoeBroAPI,
         source: DocumentEditorStore.Source,
         fallbackTitle: String,
         mode: DocumentMode = .view) {
        _store = State(initialValue: DocumentEditorStore(api: api, source: source))
        _mode = State(initialValue: mode)
        self.fallbackTitle = fallbackTitle
    }

    private var displayTitle: String { store.title.isEmpty ? fallbackTitle : store.title }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DocumentModeSwitch(mode: $mode)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider().overlay(JB.line)
            content
            Divider().overlay(JB.line)
            DocumentStatusBar(store: store)
        }
        .background(JB.bg.opacity(0.4))
        .jbWallpaper()
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if mode == .view, store.isMarkdown, !outline.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(outline) { h in
                            Button(String(repeating: "  ", count: max(0, h.level - 1)) + h.title) { jumpTo = h.id }
                        }
                    } label: {
                        Image(systemName: "list.bullet.indent").foregroundStyle(JB.ink2)
                    }
                    .accessibilityLabel("Outline")
                }
            }
        }
        .task { await store.load() }
        // Flush on every mode change: the text itself is safe either way, but
        // the backend should not be two seconds behind what you are reading.
        .onChange(of: mode) { _, newMode in
            if newMode == .view { editorFocused = false }
            Task { await store.flush() }
        }
        // A pushed editor can be popped mid-edit, so flush rather than lose it.
        .onDisappear { Task { await store.flush() } }
        .alert("Document", isPresented: Binding(
            get: { store.error != nil && !store.loadFailed },
            set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    @ViewBuilder
    private var content: some View {
        if store.loading {
            loadingState
        } else if store.loadFailed {
            failureState(store.error ?? "The backend didn't return this document.")
        } else if mode == .view {
            DocumentPreview(title: displayTitle, store: store, jumpTo: $jumpTo)
        } else {
            DocumentEditorBody(store: store, focused: $editorFocused)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            JBSpinner()
            Text(fallbackTitle).font(.jbMono(11)).foregroundStyle(JB.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(JBEmptyState.drawing(.plug)).font(.jbMono(12)).foregroundStyle(JB.ink3).fixedSize()
            Text(message)
                .font(.jbMono(12)).foregroundStyle(JB.ink2)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await store.load() } }
                .buttonStyle(.jbPrimary)
                .padding(.top, 2)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Mode switch

/// Quiet View / Edit segmented control.
private struct DocumentModeSwitch: View {
    @Binding var mode: DocumentMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.view, label: "View")
            segment(.edit, label: "Edit")
        }
        .padding(2)
        .jbSurface(.raised, radius: JB.rControl)
        .sensoryFeedback(.selection, trigger: mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document mode")
    }

    private func segment(_ value: DocumentMode, label: String) -> some View {
        let active = mode == value
        return Button {
            withAnimation(JB.snap) { mode = value }
        } label: {
            Text(label).font(.jb(13, .medium))
                .foregroundStyle(active ? JB.ink : JB.ink3)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(active ? JB.hover : .clear, in: RoundedRectangle(cornerRadius: JB.rControl - 2, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Markdown outline

/// A markdown document split at headings so each can be scrolled to.
struct MDSection: Identifiable {
    let id: Int
    let level: Int      // 0 = preamble before the first heading
    let title: String
    let body: String

    static func parse(_ text: String) -> [MDSection] {
        var out: [MDSection] = []
        var level = 0, title = "", buf: [Substring] = []
        var fenced = false
        func flush() {
            let body = buf.joined(separator: "\n")
            if level > 0 || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(MDSection(id: out.count, level: level, title: title, body: body))
            }
            buf = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle() }
            if !fenced, line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                let rest = line.dropFirst(hashes)
                if hashes <= 6, rest.first == " " {
                    flush()
                    level = hashes
                    title = rest.trimmingCharacters(in: .whitespaces)
                    buf = [line]
                    continue
                }
            }
            buf.append(line)
        }
        flush()
        return out
    }
}

// MARK: - Rendered side

/// Read-only rendering: markdown through the shared renderer, code as
/// monospaced text in a card, plain prose with reading line spacing.
private struct DocumentPreview: View {
    let title: String
    let store: DocumentEditorStore
    @Binding var jumpTo: Int?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.jb(22, .semibold)).tracking(-0.3)
                    .foregroundStyle(JB.ink)
                    .textSelection(.enabled)
                body(for: store.text)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.immediately)
        .onChange(of: jumpTo) { _, id in
            guard let id else { return }
            withAnimation(JB.smooth) { proxy.scrollTo(id, anchor: .top) }
            jumpTo = nil
        }
        }
    }

    @ViewBuilder
    private func body(for text: String) -> some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyBody
        } else if store.isMarkdown {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(MDSection.parse(text)) { sec in
                    MarkdownText(text: sec.body).textSelection(.enabled).id(sec.id)
                }
            }
        } else if store.isMonospaced {
            codeBody(text)
        } else {
            Text(text)
                .font(.jbBody)
                .lineSpacing(6)
                .foregroundStyle(JB.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func codeBody(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.jbMono(13))
                .lineSpacing(3)
                .foregroundStyle(JB.ink)
                .textSelection(.enabled)
                .padding(14)
        }
        .jbSurface(.raised, radius: JB.rCard)
    }

    private var emptyBody: some View {
        Text("Empty").font(.jbMono(12)).foregroundStyle(JB.ink3)
            .padding(.vertical, 20)
    }
}

// MARK: - Editing side

private struct DocumentEditorBody: View {
    @Bindable var store: DocumentEditorStore
    @FocusState.Binding var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if store.isLibrary {
                TextField("Document title", text: $store.title)
                    .font(.jb(17, .semibold))
                    .foregroundStyle(JB.ink)
                    .tint(JB.accent)
                    .submitLabel(.done)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .onChange(of: store.title) { _, _ in store.titleChanged() }
                Divider().overlay(JB.line)
            }
            TextEditor(text: $store.text)
                .font(store.isMonospaced ? .jbMono(14) : .jb(16))
                .lineSpacing(store.isMonospaced ? 2 : 5)
                .foregroundStyle(JB.ink)
                .tint(JB.accent)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled(store.isMonospaced)
                .textInputAutocapitalization(store.isMonospaced ? .never : .sentences)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .onChange(of: store.text) { _, _ in store.textChanged() }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
                    .foregroundStyle(JB.accent)
                    .accessibilityLabel("Dismiss keyboard")
            }
        }
    }
}

// MARK: - Status bar

/// Says plainly whether what you typed has reached the backend, plus the
/// language and a word count.
private struct DocumentStatusBar: View {
    let store: DocumentEditorStore

    var body: some View {
        HStack(spacing: 10) {
            JBChip(text: store.language.isEmpty ? "text" : store.language)
            Text(store.countSummary)
                .font(.jbMono(11))
                .foregroundStyle(JB.ink3)
            Spacer(minLength: 6)
            saveState
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 34)
        .background(JB.panelFill)
    }

    @ViewBuilder
    private var saveState: some View {
        HStack(spacing: 6) {
            if store.saving {
                JBSpinner(size: 10)
            } else if store.dirty {
                JBStatusDot(color: JB.warn, size: 6)
                Text("unsaved")
            } else if let savedAt = store.savedAt {
                JBStatusDot(color: JB.live, size: 6)
                Text(savedAt.formatted(date: .omitted, time: .shortened))
            } else {
                JBStatusDot(color: JB.ink3, size: 6)
            }
        }
        .font(.jbMono(11))
        .foregroundStyle(JB.ink3)
        .accessibilityElement(children: .combine)
    }
}
