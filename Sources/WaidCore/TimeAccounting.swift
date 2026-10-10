import Foundation

/// The time-accounting rules every report shares: how a span is clipped to a
/// range, how it is split into days, which key it is grouped under, and how
/// grouped totals are ordered. Reports pick their spans and hand them here.
///
/// Internal to WaidCore: callers use the Store's report functions.
enum TimeAccounting {
    static let noProject = "(no project)"
    static let noClient = "(no client)"
    static let noCategory = "(no category)"

    /// What a span can be grouped by. A nil project, client or category falls
    /// under the matching "(no …)" key.
    struct Labels {
        var project: String?
        var client: String?
        var category: String?
        var app: String?
        var source: String?
    }

    /// The part of a span that falls in `range`. A running span (no end) ends
    /// at `now`, or at its start if that is later.
    static func clip(start: Date, end: Date?, to range: DateInterval, now: Date) -> DateInterval {
        let start = max(start, range.start)
        return DateInterval(start: start, end: max(start, min(end ?? max(now, start), range.end)))
    }

    /// The keyed pieces of `interval` under `groupBy`. Day grouping splits at
    /// local midnight; every other grouping yields a single piece.
    static func pieces(
        of interval: DateInterval, groupBy: Store.GroupBy, labels: Labels, calendar: Calendar
    ) -> [(key: String, seconds: TimeInterval)] {
        switch groupBy {
        case .day: return splitByDay(interval, calendar: calendar)
        case .project: return [(labels.project ?? noProject, interval.duration)]
        case .client: return [(labels.client ?? noClient, interval.duration)]
        case .category: return [(labels.category ?? noCategory, interval.duration)]
        case .app: return [(labels.app ?? labels.source ?? "", interval.duration)]
        case .source: return [(labels.source ?? "", interval.duration)]
        }
    }

    /// Splits an interval at local midnights, keyed "yyyy-MM-dd".
    static func splitByDay(_ interval: DateInterval, calendar: Calendar) -> [(key: String, seconds: TimeInterval)] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var pieces: [(key: String, seconds: TimeInterval)] = []
        var cursor = interval.start
        while cursor < interval.end {
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor))!
            let pieceEnd = min(dayEnd, interval.end)
            pieces.append((formatter.string(from: cursor), pieceEnd.timeIntervalSince(cursor)))
            cursor = pieceEnd
        }
        return pieces
    }

    /// Grouped rows in report order: days chronologically, everything else
    /// largest first, ties broken by key.
    static func sorted<Row>(
        _ rows: [Row], groupBy: Store.GroupBy, key: (Row) -> String, seconds: (Row) -> Double
    ) -> [Row] {
        rows.sorted { a, b in
            groupBy == .day ? key(a) < key(b) : (seconds(a), key(b)) > (seconds(b), key(a))
        }
    }
}
