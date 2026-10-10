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

    /// The range for all-time reports such as budget status.
    static let allTime = DateInterval(start: .distantPast, end: .distantFuture)

    /// What a span can be grouped by. A nil project, client or category falls
    /// under the matching "(no …)" key.
    struct Labels {
        var project: String?
        var client: String?
        var category: String?
        var app: String?
        var source: String?
    }

    /// When a span ends. A running span (no end) ends at `now`, or at its
    /// start if that is later, so it never counts negative or future time.
    static func end(start: Date, end: Date?, now: Date) -> Date {
        end ?? max(now, start)
    }

    /// The part of a span that falls in `range`, ending as `end(start:end:now:)` says.
    static func clip(start: Date, end: Date?, to range: DateInterval, now: Date) -> DateInterval {
        let spanEnd = self.end(start: start, end: end, now: now)
        let start = max(start, range.start)
        return DateInterval(start: start, end: max(start, min(spanEnd, range.end)))
    }

    /// The parts of a span that fall in any of `intervals`.
    static func clip(start: Date, end: Date?, to intervals: [DateInterval], now: Date) -> [DateInterval] {
        intervals.map { clip(start: start, end: end, to: $0, now: now) }.filter { $0.duration > 0 }
    }

    /// The smallest interval holding all of `intervals`, for picking spans to clip.
    static func hull(_ intervals: [DateInterval]) -> DateInterval? {
        guard let first = intervals.first, let last = intervals.last else { return nil }
        return DateInterval(start: first.start, end: last.end)
    }

    /// The keyed pieces of `interval` under `groupBy`. Day grouping splits by
    /// local date; every other grouping yields a single piece.
    static func pieces(
        of interval: DateInterval, groupBy: Store.GroupBy, labels: Labels, dates: LocalDates
    ) -> [(key: String, seconds: TimeInterval)] {
        switch groupBy {
        case .day: return dates.split(interval)
        case .project: return [(labels.project ?? noProject, interval.duration)]
        case .client: return [(labels.client ?? noClient, interval.duration)]
        case .category: return [(labels.category ?? noCategory, interval.duration)]
        case .app: return [(labels.app ?? labels.source ?? "", interval.duration)]
        case .source: return [(labels.source ?? "", interval.duration)]
        }
    }

    /// Which Local date each instant falls on: the date where you were, per
    /// the zone history (GLOSSARY.md, ADR-0001). Time before the first record
    /// is in the first recorded zone; with no history at all, `fallback` is used.
    struct LocalDates {
        /// Zone changes, oldest first.
        var history: [ZoneChange]
        var fallback: TimeZone

        func zone(at date: Date) -> TimeZone {
            (history.last { $0.effectiveFrom <= date } ?? history.first)?.zone ?? fallback
        }

        /// The instants a report range covers, as disjoint intervals in order.
        /// A run of local dates is usually one interval, but flying west can
        /// repeat a date, and then it is more than one.
        func intervals(_ range: ReportRange) -> [DateInterval] {
            guard case .localDates(let dates) = range else {
                if case .instants(let interval) = range { return [interval] }
                return []
            }
            // Each zone holds from its change until the next; the first also covers all earlier time.
            let zones = history.isEmpty ? [ZoneChange(zone: fallback, effectiveFrom: .distantPast)] : history
            var result: [DateInterval] = []
            for (i, change) in zones.enumerated() {
                let from = i == 0 ? Date.distantPast : change.effectiveFrom
                let until = i + 1 < zones.count ? zones[i + 1].effectiveFrom : .distantFuture
                let start = max(from, dates.lowerBound.start(in: change.zone))
                let end = min(until, dates.upperBound.adding(days: 1).start(in: change.zone))
                guard start < end else { continue }
                if let last = result.last, last.end == start {
                    result[result.count - 1] = DateInterval(start: last.start, end: end)
                } else {
                    result.append(DateInterval(start: start, end: end))
                }
            }
            return result
        }

        /// Splits an interval at zone changes, then each piece at its local
        /// midnights, keyed by local date "yyyy-MM-dd".
        func split(_ interval: DateInterval) -> [(key: String, seconds: TimeInterval)] {
            var pieces: [(key: String, seconds: TimeInterval)] = []
            var cursor = interval.start
            while cursor < interval.end {
                let zone = self.zone(at: cursor)
                let nextChange = history.first { $0.effectiveFrom > cursor }?.effectiveFrom ?? .distantFuture
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone
                let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor))!
                let pieceEnd = min(midnight, nextChange, interval.end)
                let day = calendar.dateComponents([.year, .month, .day], from: cursor)
                let key = String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!)
                if let last = pieces.last, last.key == key {
                    pieces[pieces.count - 1].seconds += pieceEnd.timeIntervalSince(cursor)
                } else {
                    pieces.append((key, pieceEnd.timeIntervalSince(cursor)))
                }
                cursor = pieceEnd
            }
            return pieces
        }
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
