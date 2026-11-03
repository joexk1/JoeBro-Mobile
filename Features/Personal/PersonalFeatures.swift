import HealthKit
import SwiftUI

// MARK: - API

struct JBProactiveStatus: Decodable {
    let mode: String
    let descriptions: [String: String]
}

struct JBShoppingItem: Decodable, Identifiable, Hashable {
    let id: String
    let text: String
    let quantity: String
    let checked: Bool
    let addedBy: String?
    enum CodingKeys: String, CodingKey { case id, text, quantity, checked, addedBy = "added_by" }
}

private struct ShoppingEnvelope: Decodable { let items: [JBShoppingItem] }

extension JoeBroAPI {
    func proactiveStatus() async throws -> JBProactiveStatus {
        try await fetch(JBProactiveStatus.self, "api/proactive")
    }
    func setProactiveMode(_ mode: String) async throws -> JBProactiveStatus {
        try await send(JBProactiveStatus.self, "api/proactive", json: ["mode": mode])
    }
    func shoppingItems() async throws -> [JBShoppingItem] {
        try await fetch(ShoppingEnvelope.self, "api/shopping").items
    }
    @discardableResult
    func shopping(_ body: [String: Any]) async throws -> [JBShoppingItem] {
        try await send(ShoppingEnvelope.self, "api/shopping", json: body).items
    }
    func uploadHealth(days: [[String: Any]]) async throws {
        _ = try await send(OK.self, "api/personal/health", json: ["days": days])
    }
}

// MARK: - Proactive mode (Settings)

/// Off / Read only / Full — how much JoeBro may do in the background unasked.
struct ProactiveModeSection: View {
    let api: JoeBroAPI?
    @State private var mode = "read_only"
    @State private var descriptions: [String: String] = [:]
    @State private var loaded = false
    @State private var error: String?

    private let modes: [(String, String)] = [("off", "Off"), ("read_only", "Read only"), ("full", "Full")]

    var body: some View {
        Section {
            Picker("Proactive agent", selection: Binding(get: { mode }, set: { new in save(new) })) {
                ForEach(modes, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .disabled(!loaded)
            .accessibilityLabel("Proactive agent permissions")
        } header: {
            Text("Proactive agent")
        } footer: {
            Text(error ?? descriptions[mode] ?? "How much JoeBro may do in the background without being asked.")
                .foregroundStyle(error == nil ? Color.secondary : Color.red)
        }
        .listRowBackground(Color.white.opacity(0.06))
        .task { await load() }
    }

    private func load() async {
        guard let api, !loaded else { return }
        do {
            let s = try await api.proactiveStatus()
            mode = s.mode; descriptions = s.descriptions; loaded = true
        } catch { self.error = "Couldn't load: \(error.localizedDescription)" }
    }

    private func save(_ new: String) {
        let old = mode
        mode = new
        Task {
            do { _ = try await api?.setProactiveMode(new); error = nil }
            catch { mode = old; self.error = "Couldn't save: \(error.localizedDescription)" }
        }
    }
}

// MARK: - Shopping list

struct ShoppingListView: View {
    let api: JoeBroAPI
    @State private var items: [JBShoppingItem] = []
    @State private var draft = ""
    @State private var loading = true
    @State private var error: String?
    @FocusState private var adding: Bool

    private var todo: [JBShoppingItem] { items.filter { !$0.checked } }
    private var done: [JBShoppingItem] { items.filter(\.checked) }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentTint)
                    TextField("Add item", text: $draft)
                        .focused($adding)
                        .submitLabel(.done)
                        .onSubmit(add)
                        .foregroundStyle(.white)
                }
                .listRowBackground(Color.white.opacity(0.06))
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).listRowBackground(Color.clear)
            }
            if !loading && items.isEmpty {
                empty("cart", "Nothing to buy", "Add things here, or just tell JoeBro \"we're out of milk\".")
            }
            if !todo.isEmpty {
                Section("To get") { ForEach(todo) { row($0) }.onDelete { remove(todo, $0) } }
            }
            if !done.isEmpty {
                Section {
                    ForEach(done) { row($0) }.onDelete { remove(done, $0) }
                } header: {
                    HStack {
                        Text("Ticked off")
                        Spacer()
                        Button("Clear") { mutate(["action": "clear_checked"]) }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentTint)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .jbWallpaper()
        .navigationTitle("Shopping")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sensoryFeedback(.selection, trigger: done.count)
    }

    private func row(_ item: JBShoppingItem) -> some View {
        Button { toggle(item) } label: {
            HStack(spacing: 12) {
                Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(item.checked ? Color.accentTint : .white.opacity(0.45))
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                        .strikethrough(item.checked)
                        .foregroundStyle(item.checked ? .secondary : .primary)
                    if item.addedBy == "joebro" {
                        Text("Added by JoeBro").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !item.quantity.isEmpty {
                    Text(item.quantity).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.white.opacity(0.06))
        .accessibilityLabel("\(item.text)\(item.quantity.isEmpty ? "" : ", \(item.quantity)")")
        .accessibilityValue(item.checked ? "Ticked off" : "To get")
        .accessibilityAddTraits(.isButton)
    }

    private func load() async {
        do { items = try await api.shoppingItems(); error = nil }
        catch { self.error = "Couldn't load the list. \(error.localizedDescription)" }
        loading = false
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        adding = true
        mutate(["action": "add", "item": text])
    }

    private func toggle(_ item: JBShoppingItem) {
        // Optimistic: the tick lands instantly, the server confirms.
        if let i = items.firstIndex(of: item) {
            items[i] = JBShoppingItem(id: item.id, text: item.text, quantity: item.quantity,
                                      checked: !item.checked, addedBy: item.addedBy)
        }
        mutate(["action": "toggle", "id": item.id])
    }

    private func remove(_ source: [JBShoppingItem], _ offsets: IndexSet) {
        for i in offsets { mutate(["action": "remove", "id": source[i].id]) }
    }

    private func mutate(_ body: [String: Any]) {
        Task {
            do { items = try await api.shopping(body); error = nil }
            catch { self.error = "Couldn't save. \(error.localizedDescription)"; await load() }
        }
    }
}

// MARK: - Apple Health

/// Reads daily aggregates from HealthKit (read-only) and uploads them to the
/// JoeBro backend, where the personal agent can review them (health_data tool)
/// and the weekly recap is built. Raw samples never leave the phone.
@MainActor
final class HealthSync: ObservableObject {
    static let shared = HealthSync()
    private let store = HKHealthStore()
    @Published private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: "healthLastSync") as? Date
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @AppStorage("healthSyncEnabled") var enabled = false

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    private var quantityTypes: [(String, HKQuantityTypeIdentifier, HKUnit, Bool)] {
        // key, type, unit, cumulative (sum) vs discrete (average)
        [("steps", .stepCount, .count(), true),
         ("active_kcal", .activeEnergyBurned, .kilocalorie(), true),
         ("exercise_min", .appleExerciseTime, .minute(), true),
         ("distance_km", .distanceWalkingRunning, .meterUnit(with: .kilo), true),
         ("resting_hr", .restingHeartRate, .count().unitDivided(by: .minute()), false),
         ("hrv_ms", .heartRateVariabilitySDNN, .secondUnit(with: .milli), false),
         ("weight_kg", .bodyMass, .gramUnit(with: .kilo), false)]
    }

    private var readTypes: Set<HKObjectType> {
        var set = Set<HKObjectType>(quantityTypes.map { HKQuantityType($0.1) })
        set.insert(HKCategoryType(.sleepAnalysis))
        set.insert(HKObjectType.workoutType())
        return set
    }

    func connect() async -> Bool {
        guard available else { status = "Health data isn't available on this device."; return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            enabled = true
            return true
        } catch {
            status = "Couldn't get access: \(error.localizedDescription)"
            return false
        }
    }

    /// Sync if enabled and the last sync is older than `minInterval`.
    func syncIfDue(api: JoeBroAPI?, minInterval: TimeInterval = 4 * 3600) async {
        guard enabled, let api, !busy else { return }
        if let lastSync, Date().timeIntervalSince(lastSync) < minInterval { return }
        await sync(api: api)
    }

    func sync(api: JoeBroAPI, days: Int = 30) async {
        guard available, !busy else { return }
        busy = true; status = "Syncing…"
        defer { busy = false }
        let cal = Calendar.current
        let end = cal.startOfDay(for: .now).addingTimeInterval(86400)
        guard let start = cal.date(byAdding: .day, value: -days, to: end) else { return }
        var byDay: [String: [String: Any]] = [:]
        let fmt = DateFormatter()
        fmt.calendar = cal; fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        func put(_ date: Date, _ key: String, _ value: Any) {
            let d = fmt.string(from: date)
            byDay[d, default: ["day": d]][key] = value
        }
        let range = HKQuery.predicateForSamples(withStart: start, end: end)
        for (key, id, unit, cumulative) in quantityTypes {
            let type = HKQuantityType(id)
            let descriptor = HKStatisticsCollectionQueryDescriptor(
                predicate: HKSamplePredicate.quantitySample(type: type, predicate: range),
                options: cumulative ? .cumulativeSum : .discreteAverage,
                anchorDate: start, intervalComponents: DateComponents(day: 1))
            guard let collection = try? await descriptor.result(for: store) else { continue }
            collection.enumerateStatistics(from: start, to: end) { stats, _ in
                let q = cumulative ? stats.sumQuantity() : stats.averageQuantity()
                if let q { put(stats.startDate, key, (q.doubleValue(for: unit) * 100).rounded() / 100) }
            }
        }
        // Sleep: asleep stages summed, credited to the morning the night ends.
        let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                                HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        let sleepQuery = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: range)],
            sortDescriptors: [SortDescriptor(\.startDate)])
        if let samples = try? await sleepQuery.result(for: store) {
            var hours: [String: Double] = [:]
            for s in samples where asleep.contains(s.value) {
                hours[fmt.string(from: s.endDate), default: 0] += s.endDate.timeIntervalSince(s.startDate) / 3600
            }
            for (d, h) in hours { byDay[d, default: ["day": d]]["sleep_hours"] = (h * 100).rounded() / 100 }
        }
        let workoutQuery = HKSampleQueryDescriptor(
            predicates: [.workout(range)], sortDescriptors: [SortDescriptor(\.startDate)])
        if let workouts = try? await workoutQuery.result(for: store) {
            for w in workouts {
                let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
                let entry: [String: Any] = ["type": Self.name(w.workoutActivityType),
                                            "minutes": (w.duration / 60).rounded(), "kcal": kcal.rounded()]
                let d = fmt.string(from: w.startDate)
                var list = byDay[d, default: ["day": d]]["workouts"] as? [[String: Any]] ?? []
                list.append(entry)
                byDay[d, default: ["day": d]]["workouts"] = list
            }
        }
        let payload = byDay.values.filter { $0.count > 1 }.sorted { ($0["day"] as? String ?? "") < ($1["day"] as? String ?? "") }
        do {
            try await api.uploadHealth(days: payload)
            lastSync = .now
            UserDefaults.standard.set(lastSync, forKey: "healthLastSync")
            status = payload.isEmpty ? "Connected — no data yet (check Health > Sharing > Apps > JoeBro)." : "Synced \(payload.count) days."
        } catch {
            status = "Upload failed: \(error.localizedDescription)"
        }
    }

    private static func name(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: "run"
        case .walking: "walk"
        case .cycling: "cycle"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "strength"
        case .swimming: "swim"
        case .boxing, .kickboxing, .martialArts: "combat"
        case .yoga: "yoga"
        case .highIntensityIntervalTraining: "hiit"
        case .hiking: "hike"
        case .soccer: "football"
        default: "workout"
        }
    }
}

struct HealthSettingsSection: View {
    let api: JoeBroAPI?
    @ObservedObject private var health = HealthSync.shared

    var body: some View {
        Section {
            if health.enabled {
                Button {
                    Task { if let api { await health.sync(api: api) } }
                } label: {
                    HStack {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if health.busy { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(health.busy || api == nil)
                Toggle("Share with JoeBro", isOn: $health.enabled).tint(Color.accentTint)
            } else {
                Button {
                    Task { if await health.connect(), let api { await health.sync(api: api) } }
                } label: {
                    Label("Connect Apple Health", systemImage: "heart.text.square")
                }
                .disabled(!health.available)
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text(footer)
        }
        .listRowBackground(Color.white.opacity(0.06))
    }

    private var footer: String {
        var parts = ["Daily totals only (steps, sleep, heart rate, HRV, workouts, weight) go to your JoeBro server so it can review them and send a Sunday recap. Read-only."]
        if let last = health.lastSync { parts.append("Last synced \(last.formatted(.relative(presentation: .named))).") }
        if !health.status.isEmpty { parts.append(health.status) }
        return parts.joined(separator: " ")
    }
}
