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

    /// The pieces of a time entry `range` counts, each on its own local date
    /// in the entry's zone: split at that zone's midnights, then kept when
    /// its date is in the range's dates, or clipped to the range's instants.
    static func days(
        ofEntry start: Date, end: Date?, zone: TimeZone, in range: ReportRange, now: Date
    ) -> [(day: String, interval: DateInterval)] {
        days(of: clip(start: start, end: end, to: allTime, now: now), in: zone).compactMap { day, interval in
            switch range {
            case .localDates(let dates):
                return dates.contains(day) ? (day.description, interval) : nil
            case .instants(let instants):
                let clipped = clip(start: interval.start, end: interval.end, to: instants, now: now)
                return clipped.duration > 0 ? (day.description, clipped) : nil
            }
        }
    }

    /// Splits an interval at the local midnights of `zone`, each piece with its local date there.
    static func days(of interval: DateInterval, in zone: TimeZone) -> [(day: LocalDate, interval: DateInterval)] {
        var pieces: [(day: LocalDate, interval: DateInterval)] = []
        var cursor = interval.start
        while cursor < interval.end {
            let day = LocalDate(cursor, in: zone)
            let pieceEnd = min(day.adding(days: 1).start(in: zone), interval.end)
            pieces.append((day, DateInterval(start: cursor, end: pieceEnd)))
            cursor = pieceEnd
        }
        return pieces
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

    /// The key a span's time on local date `day` is grouped under.
    static func key(_ groupBy: Store.GroupBy, keys: GroupKeys, day: String) -> String {
        switch groupBy {
        case .day: return day
        case .project: return keys.project ?? noProject
        case .client: return keys.client ?? noClient
        case .category: return keys.category ?? noCategory
        case .app: return keys.app ?? keys.source ?? noSource
        case .source: return keys.source ?? noSource
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

        /// Adds `seconds` on local date `day` under `groupBy`, stored under `key(group key)`.
        mutating func add(
            _ seconds: TimeInterval, day: String, groupBy: Store.GroupBy, keys: GroupKeys,
            billable: Bool = false, as key: (String) -> Key
        ) {
            add(seconds, to: key(TimeAccounting.key(groupBy, keys: keys, day: day)), billable: billable)
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
        _ seconds: TimeInterval, day: String, groupBy: Store.GroupBy, keys: TimeAccounting.GroupKeys,
        billable: Bool = false
    ) {
        add(seconds, day: day, groupBy: groupBy, keys: keys, billable: billable) { $0 }
    }

    /// The totals as report groups, in report order.
    func groups(_ groupBy: Store.GroupBy) -> [Store.TimeGroup] {
        TimeAccounting.sorted(
            totals.map { Store.TimeGroup(key: $0.key, seconds: $0.value.seconds, billableSeconds: $0.value.billableSeconds) },
            groupBy: groupBy, key: \.key, seconds: \.seconds)
    }
}
