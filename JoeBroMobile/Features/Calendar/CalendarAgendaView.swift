import EventKit
import SwiftUI

private enum CalendarMode: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month", agenda = "Agenda"
    var id: String { rawValue }
}

private struct MobileEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let writable: Bool
    let location: String
    let notes: String

    var draft: CalendarEventDraft {
        var d = CalendarEventDraft()
        d.sourceID = id; d.title = title; d.start = start
        d.end = allDay ? (Calendar.current.date(byAdding: .day, value: -1, to: end) ?? start) : end
        d.allDay = allDay; d.location = location; d.notes = notes
        return d
    }
}

struct CalendarAgendaView: View {
    let api: JoeBroAPI
    @State private var status: JBCalendarStatus?
    @State private var events: [MobileEvent] = []
    @State private var mode: CalendarMode = .week
    @State private var anchor = Calendar.current.startOfDay(for: .now)
    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var editing: CalendarEventDraft?
    @State private var message: String?
    @State private var loading = false
    @State private var refreshGeneration = 0

    private var cal: Calendar { .current }
    private var macSource: Bool { status?.type == "macos" }
    private var calDAVSource: Bool { status?.type == "caldav" }
    private var canReadDeviceCalendar: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sourceCard
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange).padding(14).jbGlass(16) }
                    controls
                    if mode == .month { monthGrid }
                    if mode == .week { weekStrip }
                    eventList
                }
                .frame(maxWidth: 850).frame(maxWidth: .infinity).padding(16)
            }
            .scrollIndicators(.hidden)
            .jbWallpaper()
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { editing = newDraft() } label: { Image(systemName: "plus") }
                        .disabled(!calDAVSource && !(macSource && canReadDeviceCalendar))
                        .accessibilityLabel("New event")
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh calendar")
                }
            }
            .task(id: "\(mode.rawValue)-\(anchor.timeIntervalSince1970)") { await refresh() }
            .onChange(of: mode) { _, _ in anchor = selectedDay }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                if macSource { Task { await refresh() } }
            }
            .sheet(item: $editing) { draft in
                MobileEventEditor(draft: draft, onSave: saveEvent, onDelete: deleteEvent)
            }
    }

    private var sourceCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar.badge.clock").font(.title3).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 5) {
                Text(macSource ? "iPhone Calendar" : calDAVSource ? (status?.display ?? "CalDAV") : "Calendar unavailable")
                    .font(.headline)
                if macSource {
                    Text("Edit iPhone calendars here. The Mac remains JoeBro's only calendar mirror; the agent sees changes to calendars shared with that Mac after it syncs.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !canReadDeviceCalendar {
                        if EKEventStore.authorizationStatus(for: .event) == .denied {
                            Button("Open iPhone Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        } else {
                            Button("Allow calendar access") { Task { await requestDeviceAccess() } }
                        }
                    }
                } else if calDAVSource {
                    Text("Changes save to the connected CalDAV calendar.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Connect a calendar in JoeBro Settings on your Mac.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if loading { ProgressView().tint(.white) }
        }
        .padding(16).jbGlass(20)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("View", selection: $mode) {
                ForEach(CalendarMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 10) {
                Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("Previous period")
                Spacer()
                Text(periodTitle).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .accessibilityLabel("Next period")
                Button("Today") { anchor = cal.startOfDay(for: .now); selectedDay = anchor }
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(12).jbGlass(20)
    }

    private var periodTitle: String {
        switch mode {
        case .day: anchor.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        case .week: "Week of \(range.start.formatted(.dateTime.day().month(.abbreviated)))"
        case .month: anchor.formatted(.dateTime.month(.wide).year())
        case .agenda: "From \(anchor.formatted(.dateTime.day().month(.abbreviated)))"
        }
    }

    private var range: DateInterval {
        let start = cal.startOfDay(for: anchor)
        switch mode {
        case .day: return DateInterval(start: start, end: cal.date(byAdding: .day, value: 1, to: start)!)
        case .week: return cal.dateInterval(of: .weekOfYear, for: anchor)!
        case .month:
            let first = cal.dateInterval(of: .month, for: anchor)!.start
            let week = cal.dateInterval(of: .weekOfYear, for: first)!.start
            return DateInterval(start: week, end: cal.date(byAdding: .day, value: 42, to: week)!)
        case .agenda: return DateInterval(start: start, end: cal.date(byAdding: .day, value: 14, to: start)!)
        }
    }

    private func step(_ direction: Int) {
        let component: Calendar.Component = mode == .month ? .month : .day
        let amount = mode == .week ? 7 * direction : mode == .agenda ? 14 * direction : direction
        if let next = cal.date(byAdding: component, value: amount, to: anchor) {
            anchor = cal.startOfDay(for: next); selectedDay = anchor
        }
    }

    private var monthGrid: some View {
        VStack(spacing: 7) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { offset in
                    Text(cal.veryShortStandaloneWeekdaySymbols[(cal.firstWeekday - 1 + offset) % 7])
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
                ForEach(0..<42, id: \.self) { offset in
                    if let day = cal.date(byAdding: .day, value: offset, to: range.start) { dayButton(day, compact: true) }
                }
            }
        }
        .padding(12).jbGlass(20)
    }

    private var weekStrip: some View {
        HStack(spacing: 5) {
            ForEach(0..<7, id: \.self) { offset in
                if let day = cal.date(byAdding: .day, value: offset, to: range.start) { dayButton(day, compact: false) }
            }
        }
        .padding(8).jbGlass(20)
    }

    private func dayButton(_ day: Date, compact: Bool) -> some View {
        let selected = cal.isDate(day, inSameDayAs: selectedDay)
        let count = eventsOn(day).count
        return Button { selectedDay = day } label: {
            VStack(spacing: 3) {
                if !compact { Text(day.formatted(.dateTime.weekday(.narrow))).font(.caption2) }
                Text(day.formatted(.dateTime.day())).font(.subheadline.weight(selected ? .bold : .medium))
                    .foregroundStyle(cal.isDate(day, equalTo: anchor, toGranularity: .month) ? .white : .secondary)
                Circle().fill(count > 0 ? Color.cyan : .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 43 : 52)
            .background(selected ? Color.white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(count) events")
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mode == .agenda ? "Coming up" : selectedDay.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.title3.bold())
            let shown = mode == .agenda ? eventsInRange : eventsOn(mode == .day ? anchor : selectedDay)
            if shown.isEmpty {
                ContentUnavailableView("No events", systemImage: "calendar")
                    .frame(maxWidth: .infinity)
            }
            ForEach(shown) { event in
                Button {
                    if event.writable { editing = event.draft }
                    else { message = "This calendar is read-only on your iPhone." }
                } label: { eventRow(event) }.buttonStyle(.plain)
            }
        }
    }

    private func eventRow(_ event: MobileEvent) -> some View {
        HStack(alignment: .top, spacing: 13) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.start.formatted(.dateTime.day().month(.abbreviated))).font(.caption.weight(.bold))
                Text(event.allDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.headline).foregroundStyle(.white)
                if !event.location.isEmpty { Label(event.location, systemImage: "mappin").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 70, alignment: .leading).jbGlass(20)
    }

    private var eventsInRange: [MobileEvent] {
        events.filter { $0.start < range.end && $0.end > range.start }.sorted { $0.start < $1.start }
    }

    private func eventsOn(_ day: Date) -> [MobileEvent] {
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return events.filter { $0.start < end && $0.end > start }.sorted { $0.start < $1.start }
    }

    private func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        loading = true
        defer { if generation == refreshGeneration { loading = false } }
        do {
            let current = try await api.calendarStatus()
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            status = current; message = nil
            if current.type == "macos" {
                if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                    await requestDeviceAccess()
                    return
                }
                guard canReadDeviceCalendar else {
                    events = []; message = "Allow Full Calendar access to see and edit iPhone events."; return
                }
                let store = EKEventStore()
                let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
                events = store.events(matching: predicate).compactMap { event in
                    guard let id = event.eventIdentifier else { return nil }
                    return MobileEvent(id: id, title: event.title ?? "Untitled", start: event.startDate,
                                       end: event.endDate, allDay: event.isAllDay,
                                       writable: event.calendar.allowsContentModifications,
                                       location: event.location ?? "", notes: event.notes ?? "")
                }
            } else if current.type == "caldav" {
                // The backend currently ignores the date query. Filter locally.
                let fetched = try await api.calendarEvents(start: range.start, end: range.end)
                guard generation == refreshGeneration, !Task.isCancelled else { return }
                events = fetched.compactMap { event in
                    guard let start = parseDate(event.dtstart), let end = parseDate(event.dtend) else { return nil }
                    return MobileEvent(id: event.uid, title: event.summary, start: start, end: end,
                                       allDay: event.allDay, writable: true,
                                       location: event.location ?? "", notes: event.description ?? "")
                }
            } else { events = [] }
        } catch { if generation == refreshGeneration { message = error.localizedDescription } }
    }

    private func newDraft() -> CalendarEventDraft {
        var draft = CalendarEventDraft()
        let day = mode == .agenda ? anchor : selectedDay
        draft.start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        draft.end = cal.date(byAdding: .hour, value: 1, to: draft.start) ?? draft.start.addingTimeInterval(3600)
        return draft
    }

    private func requestDeviceAccess() async {
        do {
            if try await EKEventStore().requestFullAccessToEvents() { await refresh() }
            else { message = "Calendar access is off. Enable Full Access in iPhone Settings." }
        } catch { message = error.localizedDescription }
    }

    private func saveEvent(_ draft: CalendarEventDraft) async throws {
        if macSource {
            guard canReadDeviceCalendar else { throw CalendarEditError.permission }
            let store = EKEventStore()
            let event: EKEvent
            if let id = draft.sourceID {
                guard let existing = store.event(withIdentifier: id) else { throw CalendarEditError.missingEvent }
                guard existing.calendar.allowsContentModifications else { throw CalendarEditError.readOnly }
                event = existing
            } else {
                event = EKEvent(eventStore: store)
                guard let target = store.defaultCalendarForNewEvents ?? store.calendars(for: .event).first(where: \.allowsContentModifications),
                      target.allowsContentModifications else { throw CalendarEditError.noWritableCalendar }
                event.calendar = target
            }
            event.title = draft.title
            event.startDate = draft.allDay ? cal.startOfDay(for: draft.start) : draft.start
            event.endDate = draft.actualEnd
            event.isAllDay = draft.allDay
            event.location = draft.location.isEmpty ? nil : draft.location
            event.notes = draft.notes.isEmpty ? nil : draft.notes
            try store.save(event, span: .thisEvent, commit: true)
        } else if calDAVSource {
            if let id = draft.sourceID { try await api.updateCalDAVEvent(uid: id, draft: draft) }
            else { try await api.createCalDAVEvent(draft) }
        } else { throw CalendarEditError.noSource }
        await refresh()
    }

    private func deleteEvent(_ draft: CalendarEventDraft) async throws {
        guard let id = draft.sourceID else { return }
        if macSource {
            let store = EKEventStore()
            guard let event = store.event(withIdentifier: id) else { throw CalendarEditError.missingEvent }
            guard event.calendar.allowsContentModifications else { throw CalendarEditError.readOnly }
            try store.remove(event, span: .thisEvent, commit: true)
        } else if calDAVSource {
            try await api.deleteCalDAVEvent(uid: id)
        } else { throw CalendarEditError.noSource }
        await refresh()
    }

    private func parseDate(_ raw: String) -> Date? {
        if raw.count == 10 {
            let parts = raw.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3 { return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) }
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

private enum CalendarEditError: LocalizedError {
    case permission, missingEvent, readOnly, noWritableCalendar, noSource
    var errorDescription: String? {
        switch self {
        case .permission: "Full Calendar access is required."
        case .missingEvent: "This event changed or was removed. Refresh and try again."
        case .readOnly: "This calendar does not allow edits."
        case .noWritableCalendar: "No writable iPhone calendar is available."
        case .noSource: "Connect a calendar before adding events."
        }
    }
}

private struct MobileEventEditor: View {
    @State var draft: CalendarEventDraft
    let onSave: (CalendarEventDraft) async throws -> Void
    let onDelete: (CalendarEventDraft) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField("Title", text: $draft.title)
                    Toggle("All day", isOn: $draft.allDay)
                    DatePicker("Starts", selection: $draft.start,
                               displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                    DatePicker(draft.allDay ? "Last day" : "Ends", selection: $draft.end,
                               displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                    if draft.allDay { Text("The last day is included.").font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Details") {
                    TextField("Location", text: $draft.location)
                    TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...6)
                }
                if draft.sourceID != nil {
                    Section { Button("Delete event", role: .destructive) { confirmDelete = true } }
                }
            }
            .scrollContentBackground(.hidden)
            .jbWallpaper()
            .navigationTitle(draft.sourceID == nil ? "New event" : "Edit event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .disabled(busy || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.actualEnd <= draft.start)
                }
            }
            .confirmationDialog("Delete this event?", isPresented: $confirmDelete) {
                Button("Delete event", role: .destructive) { Task { await delete() } }
            }
            .alert("Calendar", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    private func save() async {
        busy = true; defer { busy = false }
        do { try await onSave(draft); dismiss() } catch { self.error = error.localizedDescription }
    }

    private func delete() async {
        busy = true; defer { busy = false }
        do { try await onDelete(draft); dismiss() } catch { self.error = error.localizedDescription }
    }
}
