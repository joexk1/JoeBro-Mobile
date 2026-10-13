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
    private let fallbackTitle: String

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
                Spacer(minLength: 0)
                DocumentModeSwitch(mode: $mode)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.16))
            Divider().overlay(.white.opacity(0.10))
            content
            Divider().overlay(.white.opacity(0.12))
            DocumentStatusBar(store: store)
        }
        .background(Color.black.opacity(0.22))
        .jbWallpaper()
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
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
            DocumentPreview(title: displayTitle, store: store)
        } else {
            DocumentEditorBody(store: store, focused: $editorFocused)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Loading \(fallbackTitle)…")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle).foregroundStyle(Color.accentTint)
            Text("Couldn't open this document").font(.headline).foregroundStyle(.white)
            Text(message)
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await store.load() } }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentTint)
                .foregroundStyle(.black)
                .padding(.top, 2)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Mode switch

/// A segmented View / Edit control with full-size touch targets and a clear
/// selected state on both the preset and photo wallpapers.
private struct DocumentModeSwitch: View {
    @Binding var mode: DocumentMode

    var body: some View {
        HStack(spacing: 3) {
            segment(.view, icon: "eye", label: "View")
            segment(.edit, icon: "square.and.pencil", label: "Edit")
        }
        .padding(3)
        .frame(maxWidth: 248)
        .background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
            .strokeBorder(.white.opacity(0.19), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document mode")
    }

    private func segment(_ value: DocumentMode, icon: String, label: String) -> some View {
        let active = mode == value
        return Button {
            withAnimation(.snappy(duration: 0.2)) { mode = value }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                Text(label).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(active ? Color.black.opacity(0.9) : .white.opacity(0.76))
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(active ? AnyShapeStyle(Color.accentTint) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Rendered side

/// Read-only rendering: markdown through the shared renderer, code as
/// monospaced text in a card, plain prose with reading line spacing.
private struct DocumentPreview: View {
    let title: String
    let store: DocumentEditorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
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
    }

    @ViewBuilder
    private func body(for text: String) -> some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyBody
        } else if store.isMarkdown {
            MarkdownText(text: text).textSelection(.enabled)
        } else if store.isMonospaced {
            codeBody(text)
        } else {
            Text(text)
                .font(.body)
                .lineSpacing(6)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func codeBody(_ text: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .lineSpacing(3)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(14)
        }
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(.white.opacity(0.1), lineWidth: 1))
    }

    private var emptyBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This document is empty.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Switch to Edit to start writing.")
                .font(.footnote).foregroundStyle(.tertiary)
        }
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
                    .font(.headline)
                    .foregroundStyle(.white)
                    .tint(Color.accentTint)
                    .submitLabel(.done)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .onChange(of: store.title) { _, _ in store.titleChanged() }
                Divider().overlay(.white.opacity(0.12))
            }
            TextEditor(text: $store.text)
                .font(store.isMonospaced ? .system(.body, design: .monospaced) : .body)
                .lineSpacing(store.isMonospaced ? 2 : 5)
                .foregroundStyle(.white)
                .tint(Color.accentTint)
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
                    .foregroundStyle(Color.accentTint)
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
            Text(store.language.isEmpty ? "text" : store.language)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.1), in: Capsule())
            Text(store.countSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            saveState
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 36)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var saveState: some View {
        HStack(spacing: 5) {
            if store.saving {
                ProgressView().controlSize(.mini).tint(.white)
                Text("Saving…")
            } else if store.dirty {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6)).foregroundStyle(.orange)
                Text("Unsaved")
            } else if let savedAt = store.savedAt {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green.opacity(0.85))
                Text("Saved \(savedAt.formatted(date: .omitted, time: .shortened))")
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Up to date")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
