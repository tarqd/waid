import Foundation

/// The time-accounting rules every report shares: how a span is clipped to a
/// range, how it is split into days, which key it is grouped under, how its
/// seconds and billable seconds are totalled, and how grouped totals are
/// ordered. Reports pick their spans and hand them here.
///
/// Internal to WaidCore: callers use the Store's report functions.
enum TimeAccounting {
    static let noProject = "(no project)"
    static let noClient = "(no client)"
    static let noCategory = "(no category)"
    static let noSource = "(no source)"

    /// The range for all-time reports such as budget status.
    static let allTime = DateInterval(start: .distantPast, end: .distantFuture)

    /// The keys a span can be grouped under. A nil project, client or
    /// category falls under the matching "(no …)" key; a nil app under the
    /// source, and a nil source under "(no source)".
    struct GroupKeys {
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

    /// Whether a span overlaps any of `intervals`, ending as `end(start:end:now:)` says.
    static func overlaps(start: Date, end: Date?, _ intervals: [DateInterval], now: Date) -> Bool {
        let spanEnd = self.end(start: start, end: end, now: now)
        return intervals.contains { start < $0.end && spanEnd > $0.start }
    }

    /// The parts of `counted` that fall in any of `intervals`: what an
    /// Activity contributes to a range.
    static func clip(_ counted: [DateInterval], to intervals: [DateInterval]) -> [DateInterval] {
        counted.flatMap { piece in intersect(piece, with: intervals) }
    }

    // MARK: Attribution

    /// `intervals` in order, overlapping or touching ones merged, and gaps no
    /// longer than `bridging` filled in.
    static func merge(_ intervals: [DateInterval], bridging gap: TimeInterval = 0) -> [DateInterval] {
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start.timeIntervalSince(last.end) <= gap {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// Present(T) (GLOSSARY.md): the active stream with gaps up to `threshold`
    /// bridged. The active observations should cover the range of interest
    /// widened by `threshold` on both sides, so a gap at its edge is judged
    /// by the input on its far side.
    static func present(active: [DateInterval], threshold: TimeInterval) -> [DateInterval] {
        merge(active, bridging: threshold)
    }

    /// The parts of `interval` inside any of `intervals`, which are disjoint and in order.
    static func intersect(_ interval: DateInterval, with intervals: [DateInterval]) -> [DateInterval] {
        intervals.compactMap { other in
            let start = max(interval.start, other.start), end = min(interval.end, other.end)
            return start < end ? DateInterval(start: start, end: end) : nil
        }
    }

    /// `intervals` with every part covered by `holes` cut out.
    static func subtract(_ holes: [DateInterval], from intervals: [DateInterval]) -> [DateInterval] {
        var pieces = intervals
        for hole in holes {
            pieces = pieces.flatMap { piece -> [DateInterval] in
                guard hole.start < piece.end, hole.end > piece.start else { return [piece] }
                var out: [DateInterval] = []
                if hole.start > piece.start { out.append(DateInterval(start: piece.start, end: hole.start)) }
                if hole.end < piece.end { out.append(DateInterval(start: hole.end, end: piece.end)) }
                return out
            }
        }
        return pieces
    }

    /// The attribution rule: the intervals an Activity counts. A window
    /// observation counts its extent where you were present and the machine
    /// wasn't locked. Any other source (an agent session) counts its full
    /// extent: it says nothing about whether you were present, and runs
    /// behind a locked screen.
    static func counted(
        extent: DateInterval, source: String, present: [DateInterval], locked: [DateInterval]
    ) -> [DateInterval] {
        guard source == Source.window else { return extent.duration > 0 ? [extent] : [] }
        return subtract(locked, from: intersect(extent, with: present))
    }

    /// The smallest interval holding all of `intervals`, for picking spans to clip.
    static func hull(_ intervals: [DateInterval]) -> DateInterval? {
        guard let first = intervals.first, let last = intervals.last else { return nil }
        return DateInterval(start: first.start, end: last.end)
    }

    /// The keyed pieces of `interval` under `groupBy`. Day grouping splits by
    /// local date; every other grouping yields a single piece.
    static func pieces(
        of interval: DateInterval, groupBy: Store.GroupBy, keys: GroupKeys, dates: LocalDates
    ) -> [(key: String, seconds: TimeInterval)] {
        switch groupBy {
        case .day: return dates.split(interval)
        case .project: return [(keys.project ?? noProject, interval.duration)]
        case .client: return [(keys.client ?? noClient, interval.duration)]
        case .category: return [(keys.category ?? noCategory, interval.duration)]
        case .app: return [(keys.app ?? keys.source ?? noSource, interval.duration)]
        case .source: return [(keys.source ?? noSource, interval.duration)]
        }
    }

    /// Exact seconds and their billable part.
    struct Total: Equatable {
        var seconds: Double = 0
        var billableSeconds: Double = 0
    }

    /// Totals per key in exact seconds, with the billable split. Every report
    /// accumulates through one of these and rounds only for display.
    struct Tally<Key: Hashable> {
        private(set) var totals: [Key: Total] = [:]

        subscript(key: Key) -> Total { totals[key] ?? Total() }

        mutating func add(_ seconds: TimeInterval, to key: Key, billable: Bool = false) {
            guard seconds > 0 else { return }
            totals[key, default: Total()].seconds += seconds
            if billable { totals[key, default: Total()].billableSeconds += seconds }
        }

        /// Adds the keyed pieces of `interval` under `groupBy`, each stored under `key(piece key)`.
        mutating func add(
            _ interval: DateInterval, groupBy: Store.GroupBy, keys: GroupKeys, dates: LocalDates,
            billable: Bool = false, as key: (String) -> Key
        ) {
            for (piece, seconds) in pieces(of: interval, groupBy: groupBy, keys: keys, dates: dates) {
                add(seconds, to: key(piece), billable: billable)
            }
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
            let dates: ClosedRange<LocalDate>
            switch range {
            case .instants(let interval): return [interval]
            case .localDates(let localDates): dates = localDates
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

extension TimeAccounting.Tally where Key == String {
    mutating func add(
        _ interval: DateInterval, groupBy: Store.GroupBy, keys: TimeAccounting.GroupKeys,
        dates: TimeAccounting.LocalDates, billable: Bool = false
    ) {
        add(interval, groupBy: groupBy, keys: keys, dates: dates, billable: billable) { $0 }
    }

    /// The totals as report groups, in report order.
    func groups(_ groupBy: Store.GroupBy) -> [Store.TimeGroup] {
        TimeAccounting.sorted(
            totals.map { Store.TimeGroup(key: $0.key, seconds: $0.value.seconds, billableSeconds: $0.value.billableSeconds) },
            groupBy: groupBy, key: \.key, seconds: \.seconds)
    }
}
