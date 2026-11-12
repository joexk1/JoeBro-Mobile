import SwiftUI
import LocalAuthentication

@MainActor
@Observable final class MobileRuntime {
    let api: JoeBroAPI
    let chat: ChatStore
    let joeBro: ChatStore

    init() {
        let api = ServerConfig.api() ?? JoeBroAPI(baseURL: URL(string: "http://localhost")!, token: nil)
        self.api = api
        self.chat = ChatStore(api: api)
        self.joeBro = ChatStore(api: api, isMainJoeBro: true)
    }
}

private enum MainTab: Hashable {
    case joeBro, chats, agents, workspace
}

struct RootView: View {
    let theme: JoeBroTheme
    var onRepaired: () -> Void = {}
    var onForgotten: () -> Void = {}
    private let serverURL = ServerConfig.urlString
    @AppStorage("backgroundAnimation") private var backgroundAnimation = "off"
    @AppStorage("faceIDGate") private var faceIDGate = false
    @State private var runtime = MobileRuntime()
    #if DEBUG
    /// `-JoeBroTab chats|agents|workspace` picks the launch tab (screenshots, UI tests).
    @State private var selectedTab: MainTab = ["chats": .chats, "agents": .agents, "workspace": .workspace][DemoMode.option("-JoeBroTab") ?? ""] ?? .joeBro
    #else
    @State private var selectedTab: MainTab = .joeBro
    #endif
    @State private var showSettings = false
    @State private var showPushInbox = false
    @State private var push = MobilePushNotifications.shared
    @State private var unlocked = false
    @State private var importingShare = false
    @State private var activityUpdate: Task<Void, Never>?
    @State private var openSharedDraft = false
    @Environment(\.scenePhase) private var scenePhase

    private var activityPollKey: String { "\(serverURL)|\(scenePhase)" }

    var body: some View {
        ZStack {
            WallpaperBackground(theme: theme)
            if !faceIDGate || unlocked {
                TabView(selection: $selectedTab) {
                    JoeBroAgentView(store: runtime.joeBro, onOpenSettings: { showSettings = true })
                        .tabItem { Label("JoeBro", systemImage: "face.smiling") }
                        .tag(MainTab.joeBro)

                    ChatsView(store: runtime.chat, openSharedDraft: $openSharedDraft)
                        .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                        .tag(MainTab.chats)

                    AgentsTabView(api: runtime.api, chatStore: runtime.chat,
                                  mainJoeBro: runtime.joeBro,
                                  onOpenSettings: { showSettings = true },
                                  onOpenJoeBro: { selectedTab = .joeBro })
                        .tabItem { Label("Agents", systemImage: "circle.hexagongrid.fill") }
                        .tag(MainTab.agents)

                    WorkspaceHubView(api: runtime.api,
                                     onOpenSettings: { showSettings = true })
                        .tabItem { Label("Workspace", systemImage: "square.grid.2x2.fill") }
                        .tag(MainTab.workspace)
                }
                .toolbarBackground(.hidden, for: .tabBar)
                .tint(Color.accentTint)
                .environment(theme)
            } else {
                VStack(spacing: 22) {
                    Image("JoeBroLogo").resizable().scaledToFit().frame(width: 92, height: 92)
                    Text("JoeBro is locked").font(.title2.bold())
                    Button("Unlock") { Task { await authenticate() } }.buttonStyle(.borderedProminent)
                }
            }
        }
        .environment(theme)
        .onOpenURL { url in
            switch url.host {
            case "agents": selectedTab = .agents
            case "workspace": selectedTab = .workspace
            case "notifications": push.openInbox = true
            case "joebro": selectedTab = .joeBro
            default: selectedTab = .chats
            }
        }
        .sheet(isPresented: $showPushInbox) {
            NavigationStack {
                MobileNotificationInbox(api: runtime.api, focusID: push.pendingInboxID)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showPushInbox = false } } }
            }
            .environment(theme)
            .onDisappear { push.pendingInboxID = nil }
        }
        .onChange(of: push.openMainAgent) { _, open in
            if open { presentPendingMainAgentMessage() }
        }
        .onChange(of: mainAgentVisibleKey, initial: true) { _, _ in
            push.mainAgentVisible = selectedTab == .joeBro && scenePhase == .active
                && !showSettings && !showPushInbox && (!faceIDGate || unlocked)
        }
        .onChange(of: push.openInbox) { _, open in
            if open { presentPendingPushInbox() }
        }
        .sheet(isPresented: $showSettings, onDismiss: { presentPendingPushInbox() }) {
            MobileSettingsView(theme: theme,
                               onRepaired: { showSettings = false; onRepaired() },
                               onForgotten: { showSettings = false; onForgotten() })
                .environment(theme)
        }
        .task { await push.syncRegistration() }
        .onChange(of: unlocked) { _, value in
            if value { presentPendingPushInbox(); presentPendingMainAgentMessage() }
        }
        .onChange(of: faceIDGate) { _, on in
            if !on { unlocked = true } else { unlocked = false; Task { await authenticate() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                presentPendingPushInbox()
                presentPendingMainAgentMessage()
                if ShareInbox.hasPending { selectedTab = .chats; Task { await importSharedCapture() } }
                Task { await runtime.chat.reconcileAfterResume() }
                Task { await runtime.joeBro.reconcileAfterResume() }
                Task { await HealthSync.shared.syncIfDue(api: runtime.api) }
                if faceIDGate { Task { await authenticate() } }
            }
            if phase == .background, faceIDGate { unlocked = false; showPushInbox = false }
        }
        .task {
            presentPendingPushInbox()
            presentPendingMainAgentMessage()
            await JoeBroActivityController().endLegacyBriefings()
            JoeBroActivityController.startObservers()
            if faceIDGate { await authenticate() } else { unlocked = true }
            if ShareInbox.hasPending { selectedTab = .chats; await importSharedCapture() }
        }
        .onChange(of: backgroundAnimation) { _, _ in
            Task { await JoeBroActivityController().refreshScene() }
        }
        .task(id: "main|" + activityPollKey) {
            // The phone agent also writes into its chat on its own (tasks, proactive
            // notes, lock-screen replies). Pick those up while its tab is open.
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if selectedTab == .joeBro { await runtime.joeBro.refreshMainIfChanged() }
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
        .task(id: activityPollKey) {
            guard scenePhase == .active else { return }
            let activities = JoeBroActivityController()
            while !Task.isCancelled {
                // Keep the island in sync even when the Agents tab is not open.
                // This GET does not start an agent or use model tokens.
                if let snap = try? await runtime.api.agentSnapshot() {
                    if activityUpdate == nil {
                        activityUpdate = Task {
                            await activities.reconcileAgents(snap.agents, activeTurns: snap.activeTurns)
                            activityUpdate = nil
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var mainAgentVisibleKey: String {
        "\(selectedTab)|\(scenePhase)|\(showSettings)|\(showPushInbox)|\(unlocked)|\(faceIDGate)"
    }

    private func presentPendingMainAgentMessage() {
        guard push.openMainAgent, !faceIDGate || unlocked else { return }
        showSettings = false
        showPushInbox = false
        selectedTab = .joeBro
        push.openMainAgent = false
        Task { await runtime.joeBro.refreshMainIfChanged() }
    }

    private func importSharedCapture() async {
        guard !importingShare else { return }
        importingShare = true
        defer { importingShare = false }
        guard let capture = ShareInbox.read() else { return }
        do {
            await runtime.chat.newChat()
            if let image = capture.imageData {
                let uploaded = try await runtime.api.upload(data: image, filename: "shared-photo.jpg", mimeType: "image/jpeg")
                runtime.chat.pendingAttachments.append(uploaded)
            }
            if !capture.text.isEmpty {
                runtime.chat.draft = [runtime.chat.draft, capture.text].filter { !$0.isEmpty }.joined(separator: "\n")
            }
            ShareInbox.clear()
            openSharedDraft = true
        } catch {
            runtime.chat.error = "Could not import the shared photo: \(error.localizedDescription)"
        }
    }

    private func presentPendingPushInbox() {
        guard push.openInbox, scenePhase == .active, !faceIDGate || unlocked else { return }
        if showSettings { showSettings = false; return }
        selectedTab = .workspace
        showPushInbox = true
        push.openInbox = false
        // pendingInboxID stays set so the inbox can open that row; the sheet clears it on dismiss.
    }

    private func authenticate() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { unlocked = true; return }
        unlocked = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: "Unlock your JoeBro conversations")) == true
    }
}
