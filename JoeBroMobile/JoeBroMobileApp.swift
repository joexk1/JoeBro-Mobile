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

    @State private var paired = ServerConfig.isPaired
    @State private var revision = 0
    @State private var inbox = PairingInbox.shared
    @State private var confirm: PairingPayload?

    var body: some Scene {
        WindowGroup {
            ZStack {
                WallpaperBackground(theme: theme)
                if !paired {
                    OnboardingView(theme: theme) { revision += 1; paired = true }
                } else if rootMounted {
                    RootView(theme: theme, onRepaired: { revision += 1 },
                             onForgotten: { revision += 1; paired = false })
                        .id(revision)
                }
                if showIntro {
                    IntroView(theme: theme) {
                        rootMounted = true
                        Task { @MainActor in
                            // Hold the matching wallpaper while Chats mounts,
                            // then reveal its content without a black frame.
                            try? await Task.sleep(for: .milliseconds(160))
                            withAnimation(.easeOut(duration: 0.32)) { showIntro = false }
                        }
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            .environment(theme)
            .onOpenURL { url in
                if url.scheme == "joebro", url.host == "notifications" {
                    MobilePushNotifications.shared.openInbox = true
                } else if let payload = PairingPayload.parse(url) {
                    if paired { confirm = payload } else { inbox.incoming = payload }
                }
            }
            .alert("Pair with a different backend?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
                Button("Pair") {
                    if let c = confirm { paired = false; inbox.incoming = c }
                    confirm = nil
                }
                Button("Cancel", role: .cancel) { confirm = nil }
            } message: {
                Text("This replaces the backend this phone is currently paired with.")
            }
            .preferredColorScheme(.dark)
            .task { if ServerConfig.isPaired { await MobilePushNotifications.shared.refresh(); LocationReporter.shared.start() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await MobilePushNotifications.shared.refresh() }; LocationReporter.shared.start() }
            }
        }
    }
}


@MainActor
final class JoeBroPushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MobilePushNotifications.shared.deviceToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await MobilePushNotifications.shared.syncRegistration() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MobilePushNotifications.shared.status = "iPhone push registration failed. Check app signing and notification settings."
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in completionHandler([.banner, .sound, .list]) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // UIKit's response completion can update state restoration; it must run on the main thread.
        Task { @MainActor in
            MobilePushNotifications.shared.openInbox = true
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
    private var syncing = false

    private var installID: String {
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
}


struct MobileNotificationInbox: View {
    let api: JoeBroAPI
    @State private var items: [Item] = []
    @State private var note: String?
    @State private var selected: Set<String> = []
    @State private var selecting = false
    @State private var deleteAll = false
    @State private var deleting = false
    @State private var opened: Item?
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
                .onTapGesture { if !selecting { opened = item } }
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
            ToolbarItem(placement: .topBarLeading) {
                Button(selecting ? "Cancel" : "Select") {
                    selecting.toggle()
                    selected = []
                    deleteAll = false
                }
                .disabled(items.isEmpty || deleting)
            }
            // ponytail: top bar, not .bottomBar - the bottom bar never shows under the tab bar/sheet
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selecting {
                    Button("All") { selected = Set(items.map(\.id)); deleteAll = true }
                        .disabled(deleting)
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
        .task { await reload() }
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
            // Opening a notification consumes it.
            .task { await delete(item.id) }
        }
    }

    private func reload() async {
        do { items = try await api.fetch(Envelope.self, "/api/inbox").inbox; note = nil }
        catch { note = "Could not load notifications. Check your backend connection." }
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
        let read: Int
    }
}
