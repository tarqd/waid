import Foundation

/// Drafts time entries from categorized activities.
///
/// The range is cut into fixed buckets, and each bucket is labeled with the
/// project that dominates it, plus the category that dominates that project's
/// time in the bucket. Runs of the same label become blocks; short
/// interruptions between two blocks with the same label are absorbed, short
/// blocks are dropped, and time already covered by entries is cut out.
public struct EntrySuggester: Sendable {
    public var bucket: TimeInterval = 60
    /// Same-label blocks this close together are merged, swallowing whatever was between them.
    public var mergeGap: TimeInterval = 5 * 60
    /// Blocks shorter than this are not suggested.
    public var minDuration: TimeInterval = 10 * 60
    /// Count agent sessions as the user's time. Off by default: agents work in
    /// parallel, and their time isn't automatically the user's to claim.
    public var includeAgents = false
    /// A bucket needs at least this fraction of active time to get a label.
    public var minActiveFraction = 0.5

    public init() {}

    public struct Label: Hashable, Sendable {
        public var projectID: Int64
        public var categoryID: Int64?
    }

    /// A title or app that contributed time to a suggested block. Not
    /// Evidence in the GLOSSARY.md sense, which is activity totals over a range.
    public struct Contributor: Codable, Equatable, Sendable {
        public var label: String
        public var seconds: Double
    }

    public struct Block: Equatable, Sendable {
        public var label: Label
        public var start: Date
        public var end: Date
        public var title: String?
        /// The biggest contributors (titles or apps) by time.
        public var contributors: [Contributor] = []
    }

    func eligible(_ activity: Activity) -> Bool {
        includeAgents || !activity.source.hasPrefix(Source.agentPrefix)
    }

    /// The dominant project (and its dominant category) of each bucket, or
    /// nil when the bucket is idle, unattributed, or contested.
    func labels(_ activities: [Activity], range: DateInterval) -> [Label?] {
        let count = Int((range.duration / bucket).rounded(.up))
        guard count > 0 else { return [] }
        // Per bucket: seconds by project (-1 = none), and by category within each project.
        var byProject = Array(repeating: [Int64: Double](), count: count)
        var byCategory = Array(repeating: [Int64: [Int64: Double]](), count: count)
        // Each counted interval of each activity, not its extent: a pause
        // inside a window activity leaves its buckets idle.
        for activity in activities where eligible(activity) {
            for counted in TimeAccounting.clip(activity.counted, to: [range]) {
                let (start, end) = (counted.start, counted.end)
                let project = activity.projectID ?? -1
                var index = Int(start.timeIntervalSince(range.start) / bucket)
                while index < count {
                    let bucketStart = range.start.addingTimeInterval(Double(index) * bucket)
                    let bucketEnd = min(bucketStart.addingTimeInterval(bucket), range.end)
                    guard bucketStart < end else { break }
                    let overlap = min(end, bucketEnd).timeIntervalSince(max(start, bucketStart))
                    byProject[index][project, default: 0] += overlap
                    if let category = activity.categoryID {
                        byCategory[index][project, default: [:]][category, default: 0] += overlap
                    }
                    index += 1
                }
            }
        }
        return (0..<count).map { i in
            let totals = byProject[i]
            let active = totals.values.reduce(0, +)
            guard active >= bucket * minActiveFraction,
                  let best = totals.filter({ $0.key != -1 }).max(by: { $0.value < $1.value }),
                  best.value >= active / 2
            else { return nil }
            let category = byCategory[i][best.key]?.max(by: { $0.value < $1.value })?.key
            return Label(projectID: best.key, categoryID: category)
        }
    }

    /// Each labeled bucket in `range` with its interval; idle, unattributed
    /// and contested buckets are left out.
    func labeledBuckets(_ activities: [Activity], range: DateInterval) -> [(interval: DateInterval, label: Label)] {
        labels(activities, range: range).enumerated().compactMap { i, label in
            guard let label else { return nil }
            return (bucketInterval(i, in: range), label)
        }
    }

    private func bucketInterval(_ i: Int, in range: DateInterval) -> DateInterval {
        let start = range.start.addingTimeInterval(Double(i) * bucket)
        return DateInterval(start: start, end: min(start.addingTimeInterval(bucket), range.end))
    }

    /// Suggested blocks in `range`, avoiding `occupied` intervals.
    public func blocks(from activities: [Activity], in range: DateInterval, avoiding occupied: [DateInterval]) -> [Block] {
        let labels = labels(activities, range: range)
        func time(_ i: Int) -> Date { min(range.start.addingTimeInterval(Double(i) * bucket), range.end) }

        // Runs of identical labels.
        var runs: [Block] = []
        for (i, label) in labels.enumerated() {
            guard let label else { continue }
            if var last = runs.last, last.label == label, last.end == time(i) {
                last.end = time(i + 1)
                runs[runs.count - 1] = last
            } else {
                runs.append(Block(label: label, start: time(i), end: time(i + 1)))
            }
        }

        // Merge same-label runs across short gaps, absorbing a short
        // interruption by something else (A, brief B, A -> one A block).
        var merged: [Block] = []
        for run in runs {
            if var last = merged.last, last.label == run.label, run.start.timeIntervalSince(last.end) <= mergeGap {
                last.end = run.end
                merged[merged.count - 1] = last
            } else if merged.count >= 2, merged[merged.count - 2].label == run.label,
                      run.start.timeIntervalSince(merged[merged.count - 2].end) <= mergeGap {
                merged.removeLast()
                merged[merged.count - 1].end = run.end
            } else {
                merged.append(run)
            }
        }

        // Cut out time already claimed by entries, then drop what's too short.
        let free = merged.flatMap { block in
            Self.subtract(occupied, from: DateInterval(start: block.start, end: block.end)).map {
                Block(label: block.label, start: $0.start, end: $0.end)
            }
        }
        return free.filter { $0.end.timeIntervalSince($0.start) >= minDuration }.map { block in
            var block = block
            block.contributors = contributors(to: block, from: activities)
            block.title = Self.title(from: block.contributors)
            return block
        }
    }

    private func contributors(to block: Block, from activities: [Activity]) -> [Contributor] {
        var totals: [String: Double] = [:]
        for activity in activities where eligible(activity) && activity.projectID == block.label.projectID {
            let overlap = activity.duration(in: DateInterval(start: block.start, end: block.end))
            guard overlap > 0 else { continue }
            totals[activity.title ?? activity.appName ?? activity.source, default: 0] += overlap
        }
        let all = totals.map { Contributor(label: $0.key, seconds: $0.value) }
        let ranked = all.sorted { a, b in a.seconds != b.seconds ? a.seconds > b.seconds : a.label < b.label }
        return Array(ranked.prefix(5))
    }

    /// The top title, plus the runner-up when it's a substantial share.
    static func title(from contributors: [Contributor]) -> String? {
        guard let first = contributors.first else { return nil }
        var title = first.label
        if contributors.count > 1, contributors[1].seconds >= first.seconds / 4 { title += " · " + contributors[1].label }
        return title.count <= 100 ? title : String(title.prefix(99)) + "…"
    }

    static func subtract(_ occupied: [DateInterval], from interval: DateInterval) -> [DateInterval] {
        TimeAccounting.subtract(occupied, from: [interval])
    }
}

extension Store {
    public struct Suggestion: Sendable {
        public var entry: TimeEntry
        /// The titles or apps that contributed most to the suggestion.
        public var contributors: [EntrySuggester.Contributor]
    }

    /// Replaces earlier suggested drafts in `range` with fresh ones, built
    /// from the activities it selects. Confirmed entries and drafts the user
    /// created are left alone and never overlapped.
    public func suggestEntries(
        in range: ReportRange, using suggester: EntrySuggester = EntrySuggester(),
        author: String = "user", now: Date = Date()
    ) throws -> [Suggestion] {
        try db.transaction {
            // Days in other zones can share instants, so clear every stretch before filling any.
            let stretches = try Self.contiguous(stretches(of: range, filter: ActivityFilter(), now: now))
            for stretch in stretches {
                try db.run(
                    "DELETE FROM time_entries WHERE origin = ? AND status = ? AND start_ts < ? AND end_ts > ?",
                    [EntryOrigin.suggested.rawValue, EntryStatus.draft.rawValue, stretch.interval.end, stretch.interval.start])
            }
            return try stretches.flatMap { stretch in
                let occupied = try timeEntries(in: stretch.interval, now: now).map {
                    DateInterval(start: $0.start, end: TimeAccounting.end(start: $0.start, end: $0.end, now: now))
                }
                let blocks = suggester.blocks(from: stretch.activities, in: stretch.interval, avoiding: occupied)
                return try blocks.map { block in
                    var new = NewTimeEntry(start: block.start, end: block.end, projectID: block.label.projectID,
                                           categoryID: block.label.categoryID, title: block.title, origin: .suggested)
                    new.status = .draft
                    new.author = author
                    return Suggestion(entry: try insertEntry(new, now: now), contributors: block.contributors)
                }
            }
        }
    }

    /// Replaces earlier suggested drafts in `range` with fresh ones.
    public func suggestEntries(
        in range: DateInterval, using suggester: EntrySuggester = EntrySuggester(),
        author: String = "user", now: Date = Date()
    ) throws -> [Suggestion] {
        try suggestEntries(in: .instants(range), using: suggester, author: author, now: now)
    }

    /// A stretch of one local date to lay buckets over: the instants that
    /// date covers in the zones its activities were stamped with (clipped to
    /// an instant range, and to `now`), and those activities.
    struct Stretch {
        var day: LocalDate
        var interval: DateInterval
        var activities: [Activity]
    }

    /// One stretch per local date `range` selects activities on, in order.
    func stretches(of range: ReportRange, filter: ActivityFilter, now: Date) throws -> [Stretch] {
        let byDay = Dictionary(grouping: try activities(in: range, filter: filter)) { LocalDate($0.localDate)! }
        return byDay.keys.sorted().flatMap { day -> [Stretch] in
            let activities = byDay[day]!
            let zones = Set(activities.map(\.zone)).compactMap(TimeZone.init(identifier:))
            let days = zones.map { DateInterval(start: day.start(in: $0), end: day.adding(days: 1).start(in: $0)) }
            return Self.union(days).compactMap { interval in
                var start = interval.start, end = min(interval.end, now)
                if case .instants(let instants) = range {
                    start = max(start, instants.start)
                    end = min(end, instants.end)
                }
                guard start < end else { return nil }
                return Stretch(day: day, interval: DateInterval(start: start, end: end), activities: activities)
            }
        }
    }

    /// Joins stretches that follow on from each other, as consecutive days in
    /// one zone do, so a block of work can run across midnight.
    private static func contiguous(_ stretches: [Stretch]) -> [Stretch] {
        stretches.reduce(into: []) { result, stretch in
            if let last = result.last, last.interval.end == stretch.interval.start {
                result[result.count - 1].interval = DateInterval(start: last.interval.start, end: stretch.interval.end)
                result[result.count - 1].activities += stretch.activities
            } else {
                result.append(stretch)
            }
        }
    }

    /// Overlapping or touching intervals joined, in order.
    private static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        intervals.sorted { $0.start < $1.start }.reduce(into: []) { result, interval in
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
    }

    // MARK: Summary and Unlogged time

    /// Time totals under one key, in exact seconds.
    public struct TimeGroup: Codable, Equatable, Sendable {
        public var key: String
        public var seconds: Double
        public var billableSeconds: Double
    }

    /// Grouped time totals over a range, in exact seconds, with the billable split.
    public struct TimeTotals: Codable, Equatable, Sendable {
        public var groups: [TimeGroup]
        /// The sum of the groups' seconds.
        public var seconds: Double
        public var billableSeconds: Double
        /// Billable ÷ total, or nil when there is no time.
        public var utilization: Double? { seconds > 0 ? billableSeconds / seconds : nil }

        init(_ tally: TimeAccounting.Tally<String>, groupBy: GroupBy) {
            groups = tally.groups(groupBy)
            seconds = groups.reduce(0) { $0 + $1.seconds }
            billableSeconds = groups.reduce(0) { $0 + $1.billableSeconds }
        }
    }

    /// Time entry totals over a range: claimed time, never observed time.
    public typealias Summary = TimeTotals

    /// Unlogged time over a range: evidence for claiming, not claimed time.
    /// Its utilization is the billable share of what is left to claim.
    public typealias UnloggedTime = TimeTotals

    /// Summaries and Unlogged time are about time you claim or could claim,
    /// which has no app or source.
    private static func requireTimeGrouping(_ groupBy: GroupBy, for what: String) throws {
        guard [.project, .client, .category, .day].contains(groupBy) else {
            throw StoreError.invalid("\(what) can be grouped by project, client, category or day, not \(groupBy.rawValue)")
        }
    }

    /// The Summary of confirmed time entries (drafts optional), grouped by
    /// project, client, category or day. A status filter, when given, decides instead.
    public func summary(
        in range: ReportRange, groupBy: GroupBy, filter: EntryFilter = EntryFilter(), includeDrafts: Bool = false,
        now: Date = Date()
    ) throws -> Summary {
        try Self.requireTimeGrouping(groupBy, for: "time entries")
        var tally = TimeAccounting.Tally<String>()
        for entry in try timeEntries(in: range, filter: filter.counting(drafts: includeDrafts), now: now) {
            let keys = TimeAccounting.GroupKeys(project: entry.project, client: entry.client, category: entry.category)
            for (day, piece) in days(of: entry, in: range, now: now) {
                tally.add(piece.duration, day: day, groupBy: groupBy, keys: keys, billable: entry.billable)
            }
        }
        return Summary(tally, groupBy: groupBy)
    }

    /// Unlogged time: work a suggestion would offer to claim (buckets where one
    /// project dominates, agents excluded) minus confirmed time entries.
    /// Project, client and category filters match the bucket's label; text,
    /// sources and uncategorized-only don't apply to a bucket and are rejected.
    /// Billable seconds follow the bucket label's project and category, by the
    /// same rule as time entries (`Catalog.defaultBillable`).
    public func unloggedTime(
        in range: ReportRange, groupBy: GroupBy, filter: ActivityFilter = ActivityFilter(),
        using suggester: EntrySuggester = EntrySuggester(), now: Date = Date()
    ) throws -> UnloggedTime {
        try Self.requireTimeGrouping(groupBy, for: "unlogged time")
        let unsupported = [
            ("text", filter.text.map { !$0.isEmpty } ?? false),
            ("sources", filter.sources.map { !$0.isEmpty } ?? false),
            ("uncategorized_only", filter.uncategorizedOnly),
        ].filter(\.1).map(\.0)
        guard unsupported.isEmpty else {
            throw StoreError.invalid("unlogged time can't be filtered by \(unsupported.joined(separator: " or ")); "
                + "it can be filtered by project, client or category")
        }
        var confirmed = EntryFilter()
        confirmed.status = .confirmed
        let catalog = try catalog()
        var observed = ActivityFilter()
        observed.includeHidden = filter.includeHidden
        var tally = TimeAccounting.Tally<String>()
        // Buckets are laid out per local date, each on the activities stamped with it.
        for stretch in try stretches(of: range, filter: observed, now: now) {
            let covered = try timeEntries(in: stretch.interval, filter: confirmed, now: now).map {
                DateInterval(start: $0.start, end: TimeAccounting.end(start: $0.start, end: $0.end, now: now))
            }
            for (bucket, label) in suggester.labeledBuckets(stretch.activities, range: stretch.interval) {
                let project = catalog.projects[label.projectID]
                if let projectID = filter.projectID, label.projectID != projectID { continue }
                if let clientID = filter.clientID, project?.clientID != clientID { continue }
                if let categoryID = filter.categoryID, label.categoryID != categoryID { continue }
                let keys = TimeAccounting.GroupKeys(
                    project: project?.path ?? "#\(label.projectID)", client: project?.client,
                    category: label.categoryID.flatMap { catalog.categories[$0]?.name })
                let billable = catalog.defaultBillable(projectID: label.projectID, categoryID: label.categoryID)
                for uncovered in EntrySuggester.subtract(covered, from: bucket) {
                    tally.add(uncovered.duration, day: stretch.day.description, groupBy: groupBy, keys: keys, billable: billable)
                }
            }
        }
        return UnloggedTime(tally, groupBy: groupBy)
    }
}
