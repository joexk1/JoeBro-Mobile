// PERSONAL add-on: two-way bridge between Apple Reminders (EventKit) and the
// personal backend's reminders extension. Not part of the production app.
#if PERSONAL
import SwiftUI
import EventKit
import CryptoKit
import UIKit

/// EventKit owns the records; the personal backend receives snapshots and acknowledged writes.
@MainActor @Observable
final class AppleRemindersSync {
    static let shared = AppleRemindersSync()
    var status = "Not connected" {
        didSet { UserDefaults.standard.set(status, forKey: "appleRemindersStatus") }
    }
    var connecting = false
    var lists: [ReminderList] = []
    var reminderCount = 0
    var defaultListID = UserDefaults.standard.string(forKey: "appleRemindersDefaultList") ?? "" {
        didSet { UserDefaults.standard.set(defaultListID, forKey: "appleRemindersDefaultList") }
    }
    var enabled = UserDefaults.standard.bool(forKey: "appleRemindersEnabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "appleRemindersEnabled") }
    }
    private var lastConnection = Date.distantPast
    private var eventStore: EKEventStore?
    private var syncing = false
    private var dirty = true
    private var lastFullSync = Date.distantPast
    private var eventObserver: NSObjectProtocol?
    private var changeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    struct ReminderList: Identifiable { let id: String; let title: String; let writable: Bool }
    private struct Change: Decodable {
        let text: String?
        let notes: String?
        let list_id: String?
        let due_at: String?
        let due_date: String?
        let priority: Int?
        let changesDue: Bool
        enum CodingKeys: String, CodingKey { case text, notes, list_id, due_at, due_date, priority }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decodeIfPresent(String.self, forKey: .text)
            notes = try c.decodeIfPresent(String.self, forKey: .notes)
            list_id = try c.decodeIfPresent(String.self, forKey: .list_id)
            due_at = try c.decodeIfPresent(String.self, forKey: .due_at)
            due_date = try c.decodeIfPresent(String.self, forKey: .due_date)
            priority = try c.decodeIfPresent(Int.self, forKey: .priority)
            changesDue = c.contains(.due_at) || c.contains(.due_date)
        }
    }
    private struct Operation: Decodable {
        let id: String
        let action: String
        let target_id: String?
        let expected_revision: String?
        let payload: Change
    }
    private struct Operations: Decodable { let operations: [Operation] }
    private struct ConnectionResponse: Decodable { let ok: Bool; let sequence: Int? }
    private struct SyncResponse: Decodable { let ok: Bool; let stale_snapshot: Bool? }
    private struct JournalEntry: Codable {
        var state: String
        var nativeID: String?
        var listID: String?
        var error: String?
        var acknowledged = false
        var started: Date
    }
    private enum SyncError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
    private var journal: [String: JournalEntry] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "appleRemindersWriteJournal") else { return [:] }
            return (try? JSONDecoder().decode([String: JournalEntry].self, from: data)) ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "appleRemindersWriteJournal") }
    }
    private func remember(_ entry: JournalEntry, for id: String) {
        var saved = journal; saved[id] = entry; journal = saved
    }
    private var store: EKEventStore {
        if let eventStore { return eventStore }
        let value = EKEventStore(); eventStore = value; return value
    }
    private var deviceID: String { MobilePushNotifications.shared.installID }
    private func client() throws -> JoeBroAPI {
        guard let api = ServerConfig.api() else {
            throw SyncError.message("Check the backend address in Settings.")
        }
        return api
    }
    private var authorization: String {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return "full"
        case .denied: return "denied"
        case .restricted: return "restricted"
        default: return "not_determined"
        }
    }

    func start() async {
        defer { if enabled { startPolling() } }
        if eventObserver == nil {
            eventObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
                Task { @MainActor in AppleRemindersSync.shared.changed() }
            }
        }
        let defaults = UserDefaults.standard
        // iOS may interrupt the first permission sheet while another system
        // sheet is active. An unfinished setup must recover on the next launch.
        if !defaults.bool(forKey: "appleRemindersSetupAttempted") ||
            (defaults.object(forKey: "appleRemindersEnabled") == nil &&
             (authorization == "full" || authorization == "not_determined")) {
            await setEnabled(true)
        } else if enabled {
            if authorization == "full" { await connect(); await sync(force: true) }
            else { await reportPermissionLoss() }
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if enabled && UIApplication.shared.applicationState == .active { await sync() }
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
    }

    func setEnabled(_ on: Bool) async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false; if enabled { startPolling() } }
        UserDefaults.standard.set(true, forKey: "appleRemindersSetupAttempted")
        if !on {
            enabled = false
            status = "Not connected"
            try? await sendConnection(enabled: false)
            return
        }
        do {
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
                status = "Waiting for Reminders permission…"
                _ = try await store.requestFullAccessToReminders()
            }
            guard authorization == "full" else {
                await reportPermissionLoss()
                return
            }
            enabled = true
            try await sendConnection(enabled: true)
            await sync(force: true)
        } catch { status = error.localizedDescription }
    }

    func connect() async {
        guard enabled else { return }
        do { try await sendConnection(enabled: authorization == "full") }
        catch { status = error.localizedDescription }
    }

    private func sendConnection(enabled: Bool) async throws {
        let api = try client()
        let response: ConnectionResponse = try await api.send(ConnectionResponse.self, "/api/reminders/connect", json: [
            "device_id": deviceID, "enabled": enabled, "authorization": authorization,
            "default_list_id": enabled ? selectedDefaultCalendar()?.calendarIdentifier ?? "" : ""
        ])
        lastConnection = .now
        if let sequence = response.sequence {
            let defaults = UserDefaults.standard
            defaults.set(max(sequence, defaults.integer(forKey: "appleRemindersSnapshotSequence")), forKey: "appleRemindersSnapshotSequence")
        }
    }
    private func reportPermissionLoss() async {
        enabled = false
        status = "Allow Reminders access in iPhone Settings"
        try? await sendConnection(enabled: false)
    }
    func chooseDefaultList(_ id: String) async {
        defaultListID = id
        await connect()
        await sync(force: true)
    }
    private func changed() {
        dirty = true
        changeTask?.cancel()
        changeTask = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            await sync()
        }
    }
    private func selectedDefaultCalendar() -> EKCalendar? {
        if !defaultListID.isEmpty, let selected = store.calendar(withIdentifier: defaultListID), selected.allowsContentModifications {
            return selected
        }
        return store.defaultCalendarForNewReminders()
    }
    private func nativeLists() -> [[String: Any]] {
        store.calendars(for: .reminder).map { calendar in
            ["id": calendar.calendarIdentifier, "title": calendar.title,
             "writable": calendar.allowsContentModifications, "source": calendar.source.title]
        }
    }
    private func allReminders() async throws -> [EKReminder] {
        guard authorization == "full" else { throw SyncError.message("Apple Reminders access was removed.") }
        let predicate = store.predicateForReminders(in: nil)
        let result: [EKReminder]? = await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { reminders in continuation.resume(returning: reminders) }
        }
        guard let result, authorization == "full" else { throw SyncError.message("Could not read Apple Reminders. Try Sync now.") }
        return result
    }

    /// Polls operations while the app is active, and refreshes changed native data.
    @discardableResult func sync(force: Bool = false) async -> Bool {
        guard enabled, !syncing else { return false }
        guard authorization == "full" else { await reportPermissionLoss(); return false }
        syncing = true
        defer { syncing = false }
        do {
            let api = try client()
            if force || Date().timeIntervalSince(lastConnection) >= 60 {
                try await sendConnection(enabled: true)
            }
            if force || dirty || Date().timeIntervalSince(lastFullSync) >= 60 || journal.values.contains(where: { !$0.acknowledged }) {
                let current = try await allReminders()
                try await publish(current, api: api)
                dirty = false
                lastFullSync = Date()
            }
            let jobs = try await api.fetch(Operations.self, "/api/reminders/operations",
                                           query: [URLQueryItem(name: "device_id", value: deviceID)])
            if !jobs.operations.isEmpty {
                var current = try await allReminders()
                for operation in jobs.operations {
                    await apply(operation, current: current)
                    current = try await allReminders()
                }
                try await publish(current, api: api)
                dirty = false
                lastFullSync = Date()
            }
            status = "Connected · \(reminderCount) reminders"
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    private func publish(_ reminders: [EKReminder], api: JoeBroAPI) async throws {
        let calendars = nativeLists()
        lists = calendars.compactMap { x in
            guard let id = x["id"] as? String, let title = x["title"] as? String else { return nil }
            return ReminderList(id: id, title: title, writable: x["writable"] as? Bool ?? false)
        }
        let rows = reminders.map(snapshot)
        let pending = journal.filter { !$0.value.acknowledged && $0.value.state != "applying" }
        let acks: [[String: Any]] = pending.map { key, value in
            ["id": key, "status": value.state, "error": value.error ?? "",
             "result": ["id": value.nativeID ?? ""]]
        }
        let defaults = UserDefaults.standard
        let sequence = defaults.integer(forKey: "appleRemindersSnapshotSequence") + 1
        defaults.set(sequence, forKey: "appleRemindersSnapshotSequence")
        let response: SyncResponse = try await api.send(SyncResponse.self, "/api/reminders/sync", json: [
            "device_id": deviceID, "sequence": sequence, "complete_snapshot": true,
            "lists": calendars, "reminders": rows, "acks": acks,
            "default_list_id": selectedDefaultCalendar()?.calendarIdentifier ?? ""
        ])
        guard response.ok else { throw SyncError.message("A newer reminder sync is already saved. Tap Sync now.") }
        var saved = journal
        for key in pending.keys { saved[key]?.acknowledged = true }
        let old = saved.filter { $0.value.acknowledged }.sorted { $0.value.started > $1.value.started }.dropFirst(200)
        for entry in old { saved.removeValue(forKey: entry.key) }
        journal = saved
        reminderCount = reminders.filter { !$0.isCompleted }.count
    }

    private func snapshot(_ reminder: EKReminder) -> [String: Any] {
        var row: [String: Any] = [
            "id": reminder.calendarItemIdentifier ?? "", "external_id": reminder.calendarItemExternalIdentifier ?? "",
            "text": reminder.title ?? "", "notes": reminder.notes ?? "",
            "list_id": reminder.calendar.calendarIdentifier, "completed": reminder.isCompleted,
            "priority": reminder.priority, "recurring": !(reminder.recurrenceRules ?? []).isEmpty,
            "all_day": false, "due_at": NSNull(), "due_date": NSNull()
        ]
        if let components = reminder.dueDateComponents {
            let calendar = components.calendar ?? Calendar.current
            if components.hour == nil && components.minute == nil {
                row["all_day"] = true
                row["due_date"] = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
            } else if let date = calendar.date(from: components) {
                row["due_at"] = Self.iso(date)
            }
        }
        // Only stable native fields participate; no sync timestamps or ordering.
        if let modified = reminder.lastModifiedDate { row["modified_at"] = Self.iso(modified) }
        let data = (try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])) ?? Data()
        row["revision"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return row
    }
    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    private func dueComponents(_ change: Change) throws -> DateComponents? {
        if let day = change.due_date {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { throw SyncError.message("Invalid reminder date.") }
            return DateComponents(calendar: Calendar.current, timeZone: TimeZone.current,
                                  year: parts[0], month: parts[1], day: parts[2])
        }
        if let raw = change.due_at {
            guard let date = Self.parse(raw) else { throw SyncError.message("Invalid reminder due time.") }
            var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            components.calendar = Calendar.current
            components.timeZone = TimeZone.current
            return components
        }
        return nil
    }

    private func apply(_ operation: Operation, current: [EKReminder]) async {
        if let previous = journal[operation.id] {
            if previous.state != "applying" { return }
            // A crash between EventKit save and journal commit is uncertain. Verify
            // a unique matching native item; never blindly create it twice.
            if operation.action == "create" {
                let matches = current.filter { item in
                    item.title == operation.payload.text && item.calendar.calendarIdentifier == previous.listID
                        && (item.notes ?? "") == (operation.payload.notes ?? "")
                        && (item.creationDate ?? .distantPast) >= previous.started.addingTimeInterval(-10)
                        && item.priority == (operation.payload.priority ?? 0)
                        && matchesDue(item, change: operation.payload)
                }
                if matches.count == 1 {
                    var entry = previous; entry.state = "applied"; entry.nativeID = matches[0].calendarItemIdentifier
                    remember(entry, for: operation.id)
                    return
                }
            }
            var entry = previous; entry.state = "failed"
            entry.error = "An earlier save was interrupted. Check Apple Reminders before retrying; no duplicate was created."
            remember(entry, for: operation.id)
            return
        }
        var entry = JournalEntry(state: "applying", started: Date())
        do {
            guard authorization == "full" else { throw SyncError.message("Apple Reminders permission is required.") }
            let reminder: EKReminder
            if operation.action == "create" {
                reminder = EKReminder(eventStore: store)
                let list = operation.payload.list_id.flatMap { store.calendar(withIdentifier: $0) } ?? selectedDefaultCalendar()
                guard let list, list.allowsContentModifications else { throw SyncError.message("Choose a writable Apple Reminders list.") }
                reminder.calendar = list
                entry.listID = list.calendarIdentifier
            } else {
                guard let id = operation.target_id,
                      let found = store.calendarItem(withIdentifier: id) as? EKReminder else {
                    throw SyncError.message("This reminder no longer exists in Apple Reminders. Refresh before retrying.")
                }
                reminder = found
                guard reminder.calendar.allowsContentModifications else { throw SyncError.message("This reminders list is read-only.") }
                if let expected = operation.expected_revision, snapshot(reminder)["revision"] as? String != expected {
                    entry.state = "conflict"; entry.error = "This reminder changed in Apple Reminders. Refresh it before retrying."
                    remember(entry, for: operation.id)
                    return
                }
            }
            remember(entry, for: operation.id)
            if operation.action == "delete" {
                let id = reminder.calendarItemIdentifier
                try store.remove(reminder, commit: true)
                entry.nativeID = id
            } else {
                if let text = operation.payload.text { reminder.title = text }
                if let notes = operation.payload.notes { reminder.notes = notes }
                if let priority = operation.payload.priority { reminder.priority = priority }
                if let listID = operation.payload.list_id, !listID.isEmpty {
                    guard let list = store.calendar(withIdentifier: listID), list.allowsContentModifications else {
                        throw SyncError.message("The target reminders list is unavailable or read-only.")
                    }
                    reminder.calendar = list
                }
                if operation.payload.changesDue {
                    let oldDue = reminder.dueDateComponents.flatMap { ($0.calendar ?? Calendar.current).date(from: $0) }
                    let newDue = try dueComponents(operation.payload)
                    let preserved = (reminder.alarms ?? []).filter { alarm in
                        if alarm.structuredLocation != nil { return true }
                        if newDue == nil && alarm.absoluteDate == nil { return false }
                        guard let oldDue, let date = alarm.absoluteDate else { return true }
                        return abs(date.timeIntervalSince(oldDue)) > 1
                    }
                    reminder.dueDateComponents = newDue
                    reminder.alarms = preserved
                    if let components = reminder.dueDateComponents, components.hour != nil,
                       let date = (components.calendar ?? Calendar.current).date(from: components) {
                        let alreadyAtDue = preserved.contains { alarm in
                            if let absolute = alarm.absoluteDate { return abs(absolute.timeIntervalSince(date)) < 1 }
                            return alarm.structuredLocation == nil && abs(alarm.relativeOffset) < 1
                        }
                        if !alreadyAtDue { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
                    }
                }
                if operation.action == "complete" { reminder.isCompleted = true }
                if operation.action == "reopen" { reminder.isCompleted = false }
                try store.save(reminder, commit: true)
                entry.nativeID = reminder.calendarItemIdentifier
            }
            entry.state = "applied"
            remember(entry, for: operation.id)
        } catch {
            entry.state = "failed"; entry.error = error.localizedDescription
            remember(entry, for: operation.id)
        }
    }
    private func matchesDue(_ reminder: EKReminder, change: Change) -> Bool {
        guard let expected = try? dueComponents(change) else { return reminder.dueDateComponents == nil }
        guard let actual = reminder.dueDateComponents else { return false }
        return [Calendar.Component.year, .month, .day, .hour, .minute].allSatisfy { actual.value(for: $0) == expected.value(for: $0) }
    }
}

struct AppleRemindersSettingsSection: View {
    @State private var sync = AppleRemindersSync.shared
    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { sync.enabled }, set: { value in Task { await sync.setEnabled(value) } })) {
                Label("Apple Reminders", systemImage: "checklist")
            }
            .disabled(sync.connecting)
            LabeledContent("Status", value: sync.status)
            if sync.enabled {
                Picker("Default list", selection: Binding(get: { sync.defaultListID }, set: { id in Task { await sync.chooseDefaultList(id) } })) {
                    Text("Apple default").tag("")
                    ForEach(sync.lists.filter(\.writable)) { list in Text(list.title).tag(list.id) }
                }
                Button("Sync now") { Task { await sync.sync(force: true) } }
            } else if EKEventStore.authorizationStatus(for: .reminder) == .denied {
                Button("Open iPhone settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        } header: { Text("Reminders") }
        .listRowBackground(Color.joeInk.opacity(0.06))
    }
}
#endif
