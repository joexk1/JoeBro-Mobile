import SwiftUI
import UIKit
import UserNotifications
import Observation

@main
struct JoeBroMobileApp: App {
    @UIApplicationDelegateAdaptor(JoeBroPushDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var theme = JoeBroTheme()
    @State private var showIntro = true
    @State private var rootMounted = false

    @State private var paired: Bool
    @State private var demo = DemoMode.active
    @State private var revision = 0
    @State private var inbox = PairingInbox.shared
    @State private var confirm: PairingPayload?

    init() {
        #if PERSONAL
        PersonalSetup.seedPairingIfNeeded()
        #endif
        _paired = State(initialValue: ServerConfig.isPaired || DemoMode.active)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                WallpaperBackground(theme: theme)
                if !paired {
                    OnboardingView(theme: theme, onPaired: { setDemo(false); revision += 1; paired = true },
                                   onDemo: { setDemo(true); revision += 1; paired = true })
                } else if rootMounted {
                    RootView(theme: theme, onRepaired: { setDemo(false); revision += 1 },
                             onForgotten: { setDemo(false); revision += 1; paired = false })
                        .id(revision)
                }
                if showIntro {
                    IntroView(theme: theme) {
                        rootMounted = true
                        Task { @MainActor in
                            // Hold the matching wallpaper while Chats mounts,
                            // then reveal its content without a black frame.
                            try? await Task.sleep(for: .milliseconds(160))
                            // Root renders under the opaque intro from launch, preloading
                            // WebKit; hold the intro until a selected header scene has drawn.
                            let hasScene = paired && theme.wallpaperName != "photo"
                                && BackgroundAnimation(rawValue: UserDefaults.standard.string(forKey: "backgroundAnimation") ?? "off").map { $0 != .off } == true
                            let deadline = Date().addingTimeInterval(4)
                            while hasScene && !AsciiSceneReadiness.shared.ready && Date() < deadline {
                                try? await Task.sleep(for: .milliseconds(40))
                            }
                            withAnimation(.easeOut(duration: 0.32)) { showIntro = false }
                        }
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .toggleStyle(JoeSwitchStyle())   // every switch: green when on, whatever the colour theme
            .safeAreaInset(edge: .top, spacing: 0) {
                if demo && !DemoMode.hidesBanner {
                    Text("Demo mode: sample data, not connected to a Mac")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 3).background(Color.yellow)
                }
            }
            .environment(theme)
            #if DEBUG
            .overlay { JoeBroDemoActivity.snapshotOverlay() }
            #endif
            .onOpenURL { url in
                if url.scheme == "joebro", url.host == "notifications" {
                    MobilePushNotifications.shared.openInbox = true
                } else if let payload = PairingPayload.parse(url) {
                    if paired { confirm = payload } else { inbox.incoming = payload }
                }
            }
            .alert("Pair with a different backend?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
                Button("Pair") {
                    if let c = confirm { setDemo(false); paired = false; inbox.incoming = c }
                    confirm = nil
                }
                Button("Cancel", role: .cancel) { confirm = nil }
            } message: {
                Text("This replaces the backend this phone is currently paired with.")
            }
            .preferredColorScheme(theme.preset == .monochrome ? nil : .dark)
            .task {
                guard ServerConfig.isPaired, !DemoMode.active else { return }
                await MobilePushNotifications.shared.refresh()
                LocationReporter.shared.start()
                #if PERSONAL
                await AppleRemindersSync.shared.start()
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                // Nothing here may run before pairing: it would prompt for
                // permissions and call a backend that is not there yet.
                guard phase == .active, ServerConfig.isPaired, !DemoMode.active else { return }
                Task { await MobilePushNotifications.shared.refresh() }
                LocationReporter.shared.start()
                #if PERSONAL
                Task { await AppleRemindersSync.shared.start(); await AppleRemindersSync.shared.sync(force: true) }
                #endif
            }
        }
    }

    private func setDemo(_ on: Bool) { DemoMode.active = on; demo = on }
}


@MainActor
final class JoeBroPushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories(MobilePushNotifications.categories)
        return true
    }

    #if PERSONAL
    /// Silent push from the backend: the agent changed a reminder, mirror it into Apple Reminders.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let info = userInfo["joebro"] as? [String: Any]
        guard info?["kind"] as? String == "reminders_sync" else { completionHandler(.noData); return }
        Task { @MainActor in
            let updated = await AppleRemindersSync.shared.sync(force: true)
            completionHandler(updated ? .newData : .failed)
        }
    }
    #endif

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MobilePushNotifications.shared.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await MobilePushNotifications.shared.syncRegistration() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MobilePushNotifications.shared.status = "iPhone push registration failed. Check app signing and notification settings."
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let fromMainAgent = Self.isMainAgentMessage(notification.request.content.userInfo["joebro"] as? [String: Any])
        Task { @MainActor in
            // The message is already on screen when the phone agent's own tab is open.
            let visible = fromMainAgent && MobilePushNotifications.shared.mainAgentVisible
            completionHandler(visible ? [] : [.banner, .sound, .list])
        }
    }

    /// A message the phone agent wrote into its own chat (not a coding-agent event routed through it).
    nonisolated private static func isMainAgentMessage(_ info: [String: Any]?) -> Bool {
        let kind = info?["kind"] as? String ?? ""
        return info?["session"] as? String == Flavor.mainSessionID && kind != "coding" && !kind.hasPrefix("coding_")
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // UIKit's response completion can update state restoration; it must run on the main thread.
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo["joebro"] as? [String: Any]
        let agent = info?["agent"] as? String
        let inboxID = info?["inbox_id"] as? String
        let fromMainAgent = Self.isMainAgentMessage(info)
        let messageID = (info?["message_id"] as? String).flatMap(Int.init)
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        let nightTask = info?["kind"] as? String == "night_review" ? info?["task"] as? String : nil
        Task { @MainActor in
            if let nightTask, [MobilePushNotifications.nightApproveAction, MobilePushNotifications.nightRejectAction, MobilePushNotifications.nightFollowupAction].contains(action) {
                let background = UIApplication.shared.beginBackgroundTask(withName: "Night Shift decision", expirationHandler: nil)
                let decision = action == MobilePushNotifications.nightApproveAction ? "approve" : action == MobilePushNotifications.nightRejectAction ? "reject" : "followup"
                await MobilePushNotifications.shared.decideNight(task: nightTask, decision: decision, text: replyText)
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            } else if fromMainAgent, action == MobilePushNotifications.replyAction, let replyText {
                // Typed on the lock screen: send without opening the app.
                let background = UIApplication.shared.beginBackgroundTask(withName: "Reply to JoeBro", expirationHandler: nil)
                await MobilePushNotifications.shared.queueReply(replyText, messageID: messageID)
                if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            } else if fromMainAgent {
                MobilePushNotifications.shared.openMainAgent = true
            } else if let agent, action == MobilePushNotifications.approveAction || action == MobilePushNotifications.denyAction {
                // Answered from the lock screen / banner: no app UI, just tell the backend.
                await MobilePushNotifications.shared.decide(agent: agent, approve: action == MobilePushNotifications.approveAction)
            } else {
                MobilePushNotifications.shared.pendingInboxID = inboxID
                MobilePushNotifications.shared.openInbox = true
            }
            completionHandler()
        }
    }
}

@Observable @MainActor
final class MobilePushNotifications {
    static let shared = MobilePushNotifications()
    var status = "Push notifications are off"
    var enabled: Bool { UserDefaults.standard.bool(forKey: "mobilePushEnabled") }
    var deviceToken: String?
    var openInbox = false
    /// Inbox row to open once the inbox sheet is up (set by a tapped notification).
    var pendingInboxID: String?
    /// A tapped message from the phone agent: switch to its tab.
    var openMainAgent = false
    /// True while the phone agent's tab is on screen; its pushes then stay silent.
    var mainAgentVisible = false
    private var syncing = false

    // MARK: replies typed on a notification
    private var flushingReplies = false
    private struct PendingReply: Codable {
        let id: String
        let message: String
        let messageID: Int?
    }
    /// Kept on disk until the backend accepts them, so a reply typed offline is not lost.
    private var pendingReplies: [PendingReply] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "mainAgentPendingReplies")
                    ?? UserDefaults.standard.data(forKey: "personalPendingReplies") else { return [] }
            return (try? JSONDecoder().decode([PendingReply].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "mainAgentPendingReplies")
            UserDefaults.standard.removeObject(forKey: "personalPendingReplies")
        }
    }

    func queueReply(_ text: String, messageID: Int?) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pendingReplies.append(PendingReply(id: UUID().uuidString, message: text, messageID: messageID))
        await flushReplies()
    }

    func flushReplies() async {
        guard !flushingReplies, !pendingReplies.isEmpty, let api = client() else { return }
        flushingReplies = true
        defer { flushingReplies = false }
        for reply in pendingReplies {
            var body: [String: Any] = ["request_id": reply.id, "message": reply.message]
            if let id = reply.messageID { body["message_id"] = id }
            do {
                let _: JoeBroAPI.OK = try await api.send(JoeBroAPI.OK.self, "/api/joebro/reply", json: body)
                pendingReplies.removeAll { $0.id == reply.id }
            } catch {
                status = "Your reply is saved on this iPhone and will send when reconnected."
                break
            }
        }
    }

    var installID: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "mobilePushInstallID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "mobilePushInstallID")
        return id
    }

    private func client() -> JoeBroAPI? {
        guard let api = ServerConfig.api() else { status = "This phone is not paired yet"; return nil }
        return api
    }

    func enable() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            guard granted else {
                status = "Notifications are disabled in iPhone Settings"
                return
            }
            UserDefaults.standard.set(true, forKey: "mobilePushEnabled")
            status = "Registering this iPhone…"
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            status = "Notification permission could not be requested"
        }
    }

    func disable() async {
        guard let api = client() else { return }
        do {
            let _: JoeBroAPI.OK = try await api.send(JoeBroAPI.OK.self, "/api/push/register", json: ["install_id": installID, "enabled": false])
            UserDefaults.standard.set(false, forKey: "mobilePushEnabled")
            UIApplication.shared.unregisterForRemoteNotifications()
            deviceToken = nil
            status = "Push notifications are off"
        } catch {
            status = "Could not disable push on the server. Reconnect and retry."
        }
    }

    func refresh() async {
        await flushReplies()
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        // Existing installs can already have iOS permission without our new app preference.
        // Adopt that permission once; an explicit app-level opt-out remains respected.
        if authorized && UserDefaults.standard.object(forKey: "mobilePushEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "mobilePushEnabled")
        }
        guard enabled else { return }
        guard authorized else {
            status = "Notifications are disabled in iPhone Settings"
            return
        }
        status = "Registering this iPhone…"
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func apnsEnvironment() -> String? {
        // The signed provisioning profile determines the APNs host, including development-signed Release builds.
        guard let path = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else {
            // App Store processing can remove the embedded profile; distributed builds use production APNs.
            #if DEBUG
            return "development"
            #else
            return "production"
            #endif
        }
        guard let data = try? Data(contentsOf: path),
              let begin = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: begin.lowerBound..<data.endIndex),
              let object = try? PropertyListSerialization.propertyList(from: data[begin.lowerBound..<end.upperBound], format: nil),
              let profile = object as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String,
              ["development", "production"].contains(environment) else {
            return nil
        }
        return environment
    }

    func syncRegistration() async {
        guard enabled, !syncing, let deviceToken, let api = client() else { return }
        guard let environment = apnsEnvironment() else {
            status = "Push capability is missing from this app's signing profile"
            return
        }
        syncing = true
        defer { syncing = false }
        let hidePreviews = UserDefaults.standard.object(forKey: "hideNotificationPreviews") as? Bool ?? true
        do {
            let _: JoeBroAPI.OK = try await api.send(JoeBroAPI.OK.self, "/api/push/register", json: [
                "install_id": installID, "device_token": deviceToken, "environment": environment,
                "bundle_id": Bundle.main.bundleIdentifier ?? "",
                "hide_previews": hidePreviews, "enabled": true
            ])
            let backend: PushServerStatus = try await api.fetch(PushServerStatus.self, "/api/push/status")
            status = backend.configured ? "This iPhone is ready for JoeBro pushes" : "iPhone registered. Server push setup is still required."
        } catch {
            status = "Could not register with the backend. Check the connection and token."
        }
    }

    private struct PushServerStatus: Decodable { let configured: Bool }

    // MARK: notification actions (reply to the phone agent; approve or deny a coding agent)
    static let messageCategory = "PERSONAL_MESSAGE"   // the identifier the backend sends
    static let replyAction = "PERSONAL_REPLY"
    static let approvalCategory = "CODING_APPROVAL"
    static let approveAction = "CODING_APPROVE"
    static let denyAction = "CODING_DENY"
    static let nightCategory = "NIGHT_REVIEW"
    static let nightApproveAction = "NIGHT_APPROVE"
    static let nightRejectAction = "NIGHT_REJECT"
    static let nightFollowupAction = "NIGHT_FOLLOWUP"
    static var categories: Set<UNNotificationCategory> {
        // Night Shift morning review: approve keeps the branch (Face ID), reject deletes it (Face ID), follow-up takes typed text.
        let nApprove = UNNotificationAction(identifier: nightApproveAction, title: "Approve", options: [.authenticationRequired],
                                            icon: UNNotificationActionIcon(systemImageName: "checkmark.circle"))
        let nReject = UNNotificationAction(identifier: nightRejectAction, title: "Reject", options: [.destructive, .authenticationRequired],
                                           icon: UNNotificationActionIcon(systemImageName: "xmark.circle"))
        let nFollow = UNTextInputNotificationAction(identifier: nightFollowupAction, title: "Ask follow-up", options: [.authenticationRequired],
                                                    textInputButtonTitle: "Send", textInputPlaceholder: "What should change?")
        let night = UNNotificationCategory(identifier: nightCategory, actions: [nApprove, nReject, nFollow], intentIdentifiers: [], options: [])
        // Approving runs a command on the PC/Mac, so it needs Face ID; denying is always safe.
        let approve = UNNotificationAction(identifier: approveAction, title: "Approve",
                                           options: [.authenticationRequired],
                                           icon: UNNotificationActionIcon(systemImageName: "checkmark.circle"))
        let deny = UNNotificationAction(identifier: denyAction, title: "Deny", options: [.destructive],
                                        icon: UNNotificationActionIcon(systemImageName: "xmark.circle"))
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: "Reply",
                                                  options: [.authenticationRequired],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Reply to JoeBro")
        return [UNNotificationCategory(identifier: approvalCategory, actions: [approve, deny], intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: messageCategory, actions: [reply], intentIdentifiers: [], options: []), night]
    }

    func decideNight(task: String, decision: String, text: String? = nil) async {
        guard let api = client() else { return }
        let id = task.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? task
        var body: [String: Any] = ["decision": decision]
        if let text { body["text"] = text }
        _ = try? await api.send(JoeBroAPI.OK.self, "/api/night-shift/\(id)/decide", json: body)
    }

    func decide(agent: String, approve: Bool) async {
        guard let api = client() else { return }
        let id = agent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? agent
        _ = try? await api.send(JoeBroAPI.OK.self, "/api/coding-agents/\(id)/decide",
                                json: ["decision": approve ? "approve" : "deny"])
    }
}


struct MobileNotificationInbox: View {
    let api: JoeBroAPI
    /// Row to open as soon as it loads (the notification that was tapped).
    var focusID: String? = nil
    @State private var items: [Item] = []
    @State private var note: String?
    @State private var selected: Set<String> = []
    @State private var selecting = false
    @State private var deleteAll = false
    @State private var deleting = false
    @State private var opened: Item?
    @State private var reloading = false
    @State private var focusedID: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(JoeBroTheme.self) private var theme

    var body: some View {
        List(selection: $selected) {
            if let note { Text(note).foregroundStyle(.secondary) }
            else if items.isEmpty { Text("No notifications yet").foregroundStyle(.secondary) }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if item.read == 0 { Circle().fill(Color.accentColor).frame(width: 7, height: 7) }
                        Text(item.title.isEmpty ? "JoeBro" : item.title).font(.headline)
                    }
                    Text(item.body).textSelection(.enabled)
                    Text(item.created_at).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { if !selecting { opened = item; markRead(item.id) } }
                .tag(item.id)
                .swipeActions {
                    Button(role: .destructive) { Task { await delete(item.id) } } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .onChange(of: selected) { _, values in
            if values != Set(items.map(\.id)) { deleteAll = false }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button(selecting ? "Cancel" : "Select") {
                    selecting.toggle()
                    selected = []
                    deleteAll = false
                }
                .disabled(items.isEmpty || deleting)
                if selecting {
                    Button("All") { selected = Set(items.map(\.id)); deleteAll = true }
                        .disabled(deleting)
                }
            }
            // ponytail: top bar, not .bottomBar - the bottom bar never shows under the tab bar/sheet
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selecting {
                    Button(role: .destructive) { Task { await deleteSelection() } } label: {
                        Label(deleteAll ? "Delete all" : "Delete selected", systemImage: "trash")
                    }
                    .tint(.red)
                    .disabled(selected.isEmpty || deleting)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .jbWallpaper()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            #if DEBUG
            NSLog("JoeBro notification inbox rendered")
            #endif
        }
        .task(id: focusID) {
            focusedID = nil
            await reload()
            // New notices arrive while the list is open; keep it current.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                if scenePhase == .active && !deleting && !selecting && opened == nil { await reload() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reload() } }
        }
        .refreshable { await reload() }
        .sheet(item: $opened) { item in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(item.title.isEmpty ? "JoeBro" : item.title).font(.headline)
                        Text(item.body).textSelection(.enabled)
                        Text(item.created_at).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle("Notification")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { opened = nil } } }
            }
            .environment(theme)
            // Viewing marks it read; the row stays until it is deleted.
            .task { markRead(item.id) }
        }
    }

    private func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].read == 0 else { return }
        items[index].read = 1
        Task { _ = try? await api.send(JoeBroAPI.OK.self, "/api/inbox/read", json: ["id": id]) }
    }

    private func reload() async {
        guard !reloading, !deleting else { return }
        reloading = true
        defer { reloading = false }
        do {
            items = try await api.fetch(Envelope.self, "/api/inbox").inbox
            note = nil
            if let focusID, focusedID != focusID, let hit = items.first(where: { $0.id == focusID }) {
                focusedID = focusID
                opened = hit
            }
        } catch { note = "Could not load notifications. Check your backend connection." }
    }
    private func delete(_ id: String) async {
        do {
            let _: JoeBroAPI.OK = try await api.send(JoeBroAPI.OK.self, "/api/inbox/delete/" + api.segment(id))
            items.removeAll { $0.id == id }
            note = nil
        } catch { note = "Could not delete this notification. Check the connection and retry." }
    }
    private func deleteSelection() async {
        guard !selected.isEmpty, !deleting else { return }
        deleting = true
        defer { deleting = false }
        let ids = Array(selected)
        let all = deleteAll
        do {
            let request: [String: Any] = all ? ["all": true] : ["ids": ids]
            let _: JoeBroAPI.OK = try await api.send(JoeBroAPI.OK.self, "/api/inbox/delete", json: request)
            if all { items = [] } else { items.removeAll { ids.contains($0.id) } }
            selected = []
            selecting = false
            deleteAll = false
            note = nil
        } catch { note = "Could not delete notifications. Check the connection and retry." }
    }
    private struct Envelope: Decodable { let inbox: [Item] }
    private struct Item: Decodable, Identifiable {
        let id: String
        let title: String
        let body: String
        let created_at: String
        var read: Int
    }
}
