import SwiftUI

/// Deep Research on iOS: start a run with a model, watch its phase live,
/// cancel it, and read or delete anything in the library.
///
/// Navigation uses the destination-builder form of `NavigationLink`. The
/// value form needs a matching `navigationDestination(for:)`, and declaring
/// one for `String` inside a view that is itself pushed onto the Workspace
/// stack clashes with the hub's own destination table — which is what made
/// this screen refuse to open at all.
struct ResearchView: View {
    let api: JoeBroAPI
    let ws: WorkspaceAPI

    @State private var reports: [JBResearchItem] = []
    @State private var active: [JBResearchActive] = []
    @State private var phases: [String: String] = [:]
    @State private var models: [JBModelChoice] = []
    @State private var query = ""
    @State private var model: JBModelChoice?
    @State private var loading = false
    @State private var starting = false
    @State private var cancelTarget: JBResearchActive?
    @State private var deleteTarget: JBResearchItem?
    @State private var error: String?

    var body: some View {
        List {
            launcher
            if !active.isEmpty { activeSection }
            librarySection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .jbWallpaper()
        .navigationTitle("Research")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .task { await refresh() }
        .task { models = (try? await api.models()) ?? [] }
        .overlay { if loading && reports.isEmpty && active.isEmpty { ProgressView().controlSize(.large) } }
        .alert("Cancel this research run?",
               isPresented: alertBinding($cancelTarget)) {
            Button("Stop the run", role: .destructive) {
                if let run = cancelTarget { Task { await act { try await ws.cancelResearch(id: run.id) } } }
                cancelTarget = nil
            }
            Button("Keep running", role: .cancel) { cancelTarget = nil }
        } message: {
            Text("JoeBro stops “\(cancelTarget?.query ?? "")” now. Whatever it has written so far stays in the library.")
        }
        .alert("Delete this report?",
               isPresented: alertBinding($deleteTarget)) {
            Button("Delete report", role: .destructive) {
                if let report = deleteTarget { Task { await act { try await ws.deleteResearch(id: report.id) } } }
                deleteTarget = nil
            }
            Button("Keep it", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("“\(deleteTarget?.query ?? "")” is removed from the backend permanently. This can't be undone.")
        }
        .alert("Research", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    // MARK: Sections

    private var launcher: some View {
        Section("New run") {
            TextField("What should JoeBro research?", text: $query, axis: .vertical)
                .lineLimit(1...4)
                .foregroundStyle(.white)
                .listRowBackground(Color.white.opacity(0.06))
            if !models.isEmpty {
                Picker("Model", selection: $model) {
                    Text("Default").tag(JBModelChoice?.none)
                    ForEach(models) { choice in
                        Text(choice.display).tag(JBModelChoice?.some(choice))
                    }
                }
                .tint(Color.accentTint)
                .listRowBackground(Color.white.opacity(0.06))
            }
            Button {
                Task { await start() }
            } label: {
                HStack {
                    if starting { ProgressView().controlSize(.small).tint(Color.accentTint) }
                    Text(starting ? "Starting…" : "Start research")
                    Spacer()
                    Image(systemName: "sparkle.magnifyingglass")
                }
                .foregroundStyle(Color.accentTint)
                .frame(minHeight: 44)
            }
            .disabled(starting || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .listRowBackground(Color.white.opacity(0.06))
        }
    }

    private var activeSection: some View {
        Section("In progress") {
            ForEach(active) { run in
                NavigationLink {
                    ResearchReportView(api: api, ws: ws, id: run.id, title: run.query)
                } label: {
                    HStack(spacing: 13) {
                        ProgressView().controlSize(.small).tint(Color.accentTint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(run.query).foregroundStyle(.white).lineLimit(2)
                            Text(phases[run.id] ?? "Working…")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(minHeight: 48)
                }
                .listRowBackground(Color.white.opacity(0.06))
                .contextMenu {
                    Button("Stop run", systemImage: "stop.circle", role: .destructive) { cancelTarget = run }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Stop", systemImage: "stop.circle") { cancelTarget = run }.tint(.orange)
                }
            }
        }
    }

    private var librarySection: some View {
        Section("Library") {
            if reports.isEmpty && !loading {
                empty("doc.text.magnifyingglass", "No reports yet",
                      "Start a run above, or kick one off from a chat.")
            }
            ForEach(reports) { report in
                NavigationLink {
                    ResearchReportView(api: api, ws: ws, id: report.id, title: report.query)
                } label: {
                    ReportRow(report: report)
                }
                .listRowBackground(Color.white.opacity(0.06))
                .contextMenu {
                    Button("Delete report", systemImage: "trash", role: .destructive) { deleteTarget = report }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", systemImage: "trash") { deleteTarget = report }.tint(.red)
                }
            }
        }
    }

    // MARK: Work

    private func start() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        do {
            try await ws.startResearch(query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                       model: model?.modelID, endpointID: model?.endpointID)
            query = ""
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func act(_ work: () async throws -> Void) async {
        do { try await work(); await refresh() } catch { self.error = error.localizedDescription }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            async let loadedReports = api.researchLibrary()
            async let loadedActive = api.researchActive()
            reports = try await loadedReports
            active = try await loadedActive
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        for run in active {
            if let status = try? await api.researchStatus(id: run.id) {
                phases[run.id] = status.progress["phase"]?.stringValue ?? status.status.capitalized
            }
        }
    }
}

private struct ReportRow: View {
    let report: JBResearchItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.query).foregroundStyle(.white).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(minHeight: 48)
    }

    private var symbol: String {
        switch report.status {
        case "completed": "doc.text.fill"
        case "cancelled": "xmark.circle"
        case "failed": "exclamationmark.triangle"
        default: "hourglass"
        }
    }
    private var tint: Color {
        switch report.status {
        case "completed": Color.accentTint
        case "failed": .orange
        case "cancelled": .secondary
        default: .yellow
        }
    }
    private var subtitle: String {
        let date = (report.updatedAt ?? report.createdAt ?? "").prefix(16).replacingOccurrences(of: "T", with: " ")
        return date.isEmpty ? report.status.capitalized : "\(report.status.capitalized) · \(date)"
    }
}

// MARK: - Report reader

private struct ResearchReportView: View {
    let api: JoeBroAPI
    let ws: WorkspaceAPI
    let id: String
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var report: JBResearchItem?
    @State private var phase: String?
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(report?.query ?? title).font(.title2.bold()).foregroundStyle(.white)
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .jbWallpaper()
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let body = reportBody, !body.isEmpty {
                        ShareLink(item: body) { Label("Share report", systemImage: "square.and.arrow.up") }
                    }
                    Button("Delete report", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(Color.accentTint)
                }
                .accessibilityLabel("Report actions")
            }
        }
        .alert("Delete this report?", isPresented: $confirmDelete) {
            Button("Delete report", role: .destructive) { Task { await deleteReport() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("“\(report?.query ?? title)” is removed from the backend permanently. This can't be undone.")
        }
        .refreshable { await load() }
        .task(id: id) {
            await load()
            while !Task.isCancelled, let status = report?.status,
                  status == "running" || status == "queued" {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                await load()
            }
        }
        .alert("Report", isPresented: alertBinding($error)) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }

    @ViewBuilder
    private var content: some View {
        if let report {
            Label(report.status.capitalized,
                  systemImage: report.status == "completed" ? "checkmark.circle" : "circle.dotted")
                .font(.subheadline).foregroundStyle(.secondary)
            if report.status == "completed" {
                let body = reportBodyWithoutSources
                if body.isEmpty {
                    empty("doc.text", "Report is empty", "The run finished without writing anything.")
                } else {
                    MarkdownText(text: body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let sources = report.sources, !sources.isEmpty {
                    ResearchSourcesView(sources: sources)
                }
            } else if report.status == "failed" {
                MarkdownText(text: report.content ?? "Research failed.")
                    .textSelection(.enabled)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(Color.accentTint)
                    Text(phase ?? "JoeBro is working on this report.").foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .jbGlass(16)
            }
        } else if let error {
            empty("exclamationmark.triangle", "Couldn't load report", error)
        } else {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity).padding(.vertical, 50)
        }
    }

    private var reportBody: String? { report?.report ?? report?.content }
    private var reportBodyWithoutSources: String {
        let body = reportBody ?? ""
        guard report?.sources?.isEmpty == false,
              let range = body.range(of: "\n## Sources\n") else { return body }
        return String(body[..<range.lowerBound])
    }

    private func load() async {
        do {
            report = try await api.researchDetail(id: id)
            if report?.status != "completed" {
                phase = (try? await api.researchStatus(id: id))?.progress["phase"]?.stringValue
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func deleteReport() async {
        do { try await ws.deleteResearch(id: id); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

/// Shared by a research report opened from Workspace or from Agents.
struct ResearchSourcesView: View {
    let sources: [JBResearchSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sources · \(sources.count)")
                .font(.title3.bold())
                .foregroundStyle(.white)
            ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit().bold())
                                .foregroundStyle(Color.accentTint)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                            Text(url.host() ?? source.url)
                                .font(.caption)
                                .foregroundStyle(Color.accentTint)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundStyle(Color.accentTint)
                        }
                        .padding(12)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .padding(.top, 12)
    }
}
