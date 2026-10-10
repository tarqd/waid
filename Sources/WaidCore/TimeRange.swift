import Foundation

/// Parses the time ranges agents and the CLI pass around: named ranges like
/// "today" or "last_7_days", or explicit ISO 8601 dates/datetimes.
public enum TimeRange {
    public static let names = ["today", "yesterday", "this_week", "last_week", "last_7_days", "this_month", "last_30_days"]

    public static func named(_ name: String, now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        switch name.lowercased() {
        case "today": return DateInterval(start: today, end: day(1))
        case "yesterday": return DateInterval(start: day(-1), end: today)
        case "this_week":
            return calendar.dateInterval(of: .weekOfYear, for: now)
        case "last_week":
            let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now)!
            return calendar.dateInterval(of: .weekOfYear, for: lastWeek)
        case "last_7_days": return DateInterval(start: day(-6), end: day(1))
        case "this_month": return calendar.dateInterval(of: .month, for: now)
        case "last_30_days": return DateInterval(start: day(-29), end: day(1))
        default: return nil
        }
    }

    /// Accepts "2026-10-09" (local midnight), "2026-10-09T14:30:00" (local),
    /// or a full RFC 3339 timestamp with offset.
    public static func parseDate(_ string: String, calendar: Calendar = .current) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }

        let local = DateFormatter()
        local.calendar = calendar
        local.timeZone = calendar.timeZone
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: string) { return date }
        }
        return nil
    }

    public enum ParseError: Error, CustomStringConvertible {
        case unknown(String)
        case empty
        public var description: String {
            switch self {
            case .unknown(let s):
                return "can't parse time \"\(s)\"; use an ISO 8601 date/datetime or one of: \(TimeRange.names.joined(separator: ", "))"
            case .empty: return "range end must be after start"
            }
        }
    }

    /// Resolves either a named `range`, or `start`/`end`. A bare date for
    /// `end` is inclusive (covers that whole day). Defaults to today.
    public static func resolve(
        range: String?, start: String?, end: String?, now: Date = Date(), calendar: Calendar = .current
    ) throws -> DateInterval {
        if let range {
            guard let interval = named(range, now: now, calendar: calendar) else { throw ParseError.unknown(range) }
            return interval
        }
        guard start != nil || end != nil else { return named("today", now: now, calendar: calendar)! }
        let startDate = try start.map { s in try parseDate(s, calendar: calendar) ?? { throw ParseError.unknown(s) }() }
            ?? calendar.startOfDay(for: now)
        var endDate = try end.map { s in try parseDate(s, calendar: calendar) ?? { throw ParseError.unknown(s) }() } ?? now
        if let end, end.count == 10 { endDate = calendar.date(byAdding: .day, value: 1, to: endDate)! }
        guard endDate > startDate else { throw ParseError.empty }
        return DateInterval(start: startDate, end: endDate)
    }
}
