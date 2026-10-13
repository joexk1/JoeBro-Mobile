import Foundation

/// Calendar helpers.
///
/// Two backend behaviours force this to be defensive:
///  - times come back as UTC ("...Z"), so they must be converted to the
///    device's timezone before display, never string-sliced;
///  - `/api/calendar/events` ignores its `start`/`end` query parameters and
///    returns the entire mirror, so the day filter has to happen here.
enum CalendarTime {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()
    private static let localDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ raw: String) -> Date? {
        plain.date(from: raw) ?? withFractional.date(from: raw)
            ?? (raw.count == 10 ? localDay.date(from: raw) : nil)
    }

    /// Local wall-clock time, e.g. "18:00". All-day events have no useful one.
    static func clock(_ raw: String) -> String? {
        guard let date = date(raw) else { return nil }
        return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
    }

    /// Events that overlap the given day in the device's timezone, sorted.
    static func events(_ events: [JBCalendarEvent], on day: Date) -> [JBCalendarEvent] {
        let calendar = Foundation.Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events
            .filter { event in
                guard let eventStart = date(event.dtstart) else { return false }
                let parsedEnd = date(event.dtend) ?? eventStart
                let eventEnd = event.allDay && parsedEnd <= eventStart
                    ? (calendar.date(byAdding: .day, value: 1, to: eventStart) ?? eventStart.addingTimeInterval(86400))
                    : parsedEnd
                // An all-day event is stored as the preceding 22:00Z, so test
                // for overlap with the day rather than containment of a point.
                return eventStart < end && eventEnd > start
            }
            .sorted { a, b in
                if a.allDay != b.allDay { return a.allDay }
                return (date(a.dtstart) ?? .distantFuture) < (date(b.dtstart) ?? .distantFuture)
            }
    }
}
