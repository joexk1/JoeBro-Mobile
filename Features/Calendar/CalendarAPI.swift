import Foundation

extension JoeBroAPI {
    private struct CalendarMutation: Decodable {
        let ok: Bool
        let uid: String?
    }

    func createCalDAVEvent(_ event: CalendarEventDraft) async throws {
        _ = try await send(CalendarMutation.self, "api/calendar/events", json: event.body)
    }

    func updateCalDAVEvent(uid: String, draft: CalendarEventDraft) async throws {
        _ = try await send(CalendarMutation.self, "api/calendar/events/\(segment(uid))", method: "PUT", json: draft.body)
    }

    func deleteCalDAVEvent(uid: String) async throws {
        _ = try await send(CalendarMutation.self, "api/calendar/events/\(segment(uid))", method: "DELETE")
    }
}

struct CalendarEventDraft: Identifiable {
    let id = UUID()
    var sourceID: String?
    var title: String = ""
    var start: Date = .now
    /// The editor displays the last included day for all-day events.
    var end: Date = .now.addingTimeInterval(3600)
    var allDay = false
    var location = ""
    var notes = ""

    var actualEnd: Date {
        guard allDay else { return end }
        let lastDay = max(Calendar.current.startOfDay(for: start), Calendar.current.startOfDay(for: end))
        return Calendar.current.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay.addingTimeInterval(86400)
    }

    var body: [String: Any] {
        let instant = ISO8601DateFormatter()
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "yyyy-MM-dd"
        return ["summary": title.trimmingCharacters(in: .whitespacesAndNewlines),
                // The backend's all-day ICS writer takes the first ten characters
                // verbatim. UTC formatting could shift a local midnight to the
                // previous day, so send bare local dates for all-day events.
                "dtstart": allDay ? day.string(from: start) : instant.string(from: start),
                "dtend": allDay ? day.string(from: actualEnd) : instant.string(from: end),
                "all_day": allDay, "location": location, "description": notes]
    }
}
