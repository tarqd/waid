import Foundation

/// A calendar date with no zone attached, such as "2026-10-09": the Local date
/// a span falls on (GLOSSARY.md). Which instants it covers depends on the zone
/// history.
public struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses exactly "yyyy-MM-dd".
    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard string.count == 10, parts.count == 3, parts.map(\.count) == [4, 2, 2],
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
        guard adding(days: 0) == self else { return nil }
    }

    /// The local date of `date` in `zone`.
    public init(_ date: Date, in zone: TimeZone) {
        let c = Self.calendar(zone).dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (a: LocalDate, b: LocalDate) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    /// Local midnight starting this date in `zone`.
    public func start(in zone: TimeZone) -> Date {
        Self.calendar(zone).date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func adding(days: Int = 0, months: Int = 0) -> LocalDate {
        let utc = Self.utc
        let calendar = Self.calendar(utc)
        let date = calendar.date(byAdding: DateComponents(month: months, day: days), to: start(in: utc))!
        return LocalDate(date, in: utc)
    }

    /// ISO weekday: Monday is 1, Sunday is 7, whatever the locale.
    var isoWeekday: Int {
        let weekday = Self.calendar(Self.utc).component(.weekday, from: start(in: Self.utc)) // Sunday is 1
        return (weekday + 5) % 7 + 1
    }

    private static let utc = TimeZone(identifier: "UTC")!

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
}

/// What a report covers: whole Local dates (named ranges and date-only
/// inputs), or exact instants (explicit timestamps). See ADR-0001.
public enum ReportRange: Equatable, Sendable {
    case localDates(ClosedRange<LocalDate>)
    case instants(DateInterval)
}

/// Parses the time ranges agents and the CLI pass around: named ranges like
/// "today" or "last_7_days", or explicit ISO 8601 dates/datetimes.
public enum TimeRange {
    public static let names = ["today", "yesterday", "this_week", "last_week", "last_7_days", "this_month", "last_30_days"]

    /// The local dates a named range covers, counted from `today`. Weeks start
    /// on Monday whatever the locale.
    public static func named(_ name: String, today: LocalDate) -> ClosedRange<LocalDate>? {
        let monday = today.adding(days: 1 - today.isoWeekday)
        let firstOfMonth = LocalDate(year: today.year, month: today.month, day: 1)
        switch name.lowercased() {
        case "today": return today...today
        case "yesterday": return today.adding(days: -1)...today.adding(days: -1)
        case "this_week": return monday...monday.adding(days: 6)
        case "last_week": return monday.adding(days: -7)...monday.adding(days: -1)
        case "last_7_days": return today.adding(days: -6)...today
        case "this_month": return firstOfMonth...firstOfMonth.adding(days: -1, months: 1)
        case "last_30_days": return today.adding(days: -29)...today
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

    /// Resolves either a named `range`, or `start`/`end`; defaults to today.
    /// Named ranges and date-only inputs select by local date (a date-only
    /// `end` is inclusive). Anything with a time of day is an instant, read in
    /// `calendar`'s zone when it has no offset. "Today" is the local date of
    /// `now` in `calendar`'s zone.
    public static func resolve(
        range: String?, start: String?, end: String?, now: Date = Date(), calendar: Calendar = .current
    ) throws -> ReportRange {
        let today = LocalDate(now, in: calendar.timeZone)
        if let range {
            guard let dates = named(range, today: today) else { throw ParseError.unknown(range) }
            return .localDates(dates)
        }
        let startDate = start.flatMap(LocalDate.init), endDate = end.flatMap(LocalDate.init)
        if (start == nil || startDate != nil) && (end == nil || endDate != nil) {
            let first = startDate ?? today, last = endDate ?? today
            guard first <= last else { throw ParseError.empty }
            return .localDates(first...last)
        }
        let from = try start.map { s in try parseDate(s, calendar: calendar) ?? { throw ParseError.unknown(s) }() }
            ?? calendar.startOfDay(for: now)
        var to = try end.map { s in try parseDate(s, calendar: calendar) ?? { throw ParseError.unknown(s) }() } ?? now
        if endDate != nil { to = calendar.date(byAdding: .day, value: 1, to: to)! }
        guard to > from else { throw ParseError.empty }
        return .instants(DateInterval(start: from, end: to))
    }
}
