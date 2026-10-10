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

    public struct Evidence: Codable, Equatable, Sendable {
        public var label: String
        public var seconds: Double
    }

    public struct Block: Equatable, Sendable {
        public var label: Label
        public var start: Date
        public var end: Date
        public var title: String?
        /// The biggest contributors (titles or apps) by time.
        public var evidence: [Evidence] = []
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
        for activity in activities where eligible(activity) {
            let start = max(activity.start, range.start), end = min(activity.end ?? range.end, range.end)
            guard end > start else { continue }
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
            block.evidence = evidence(for: block, from: activities)
            block.title = Self.title(from: block.evidence)
            return block
        }
    }

    private func evidence(for block: Block, from activities: [Activity]) -> [Evidence] {
        var totals: [String: Double] = [:]
        for activity in activities where eligible(activity) && activity.projectID == block.label.projectID {
            let overlap = min(activity.end ?? block.end, block.end).timeIntervalSince(max(activity.start, block.start))
            guard overlap > 0 else { continue }
            totals[activity.title ?? activity.appName ?? activity.source, default: 0] += overlap
        }
        let all = totals.map { Evidence(label: $0.key, seconds: $0.value) }
        let ranked = all.sorted { a, b in a.seconds != b.seconds ? a.seconds > b.seconds : a.label < b.label }
        return Array(ranked.prefix(5))
    }

    /// The top title, plus the runner-up when it's a substantial share.
    static func title(from evidence: [Evidence]) -> String? {
        guard let first = evidence.first else { return nil }
        var title = first.label
        if evidence.count > 1, evidence[1].seconds >= first.seconds / 4 { title += " · " + evidence[1].label }
        return title.count <= 100 ? title : String(title.prefix(99)) + "…"
    }

    static func subtract(_ occupied: [DateInterval], from interval: DateInterval) -> [DateInterval] {
        var pieces = [interval]
        for hole in occupied {
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
}

extension Store {
    public struct Suggestion: Sendable {
        public var entry: TimeEntry
        public var evidence: [EntrySuggester.Evidence]
    }

    /// Replaces earlier suggested drafts in `range` with fresh ones. Confirmed
    /// entries and drafts the user created are left alone and never overlapped.
    public func suggestEntries(
        in range: DateInterval, using suggester: EntrySuggester = EntrySuggester(),
        author: String = "user", now: Date = Date()
    ) throws -> [Suggestion] {
        let range = DateInterval(start: range.start, end: max(range.start, min(range.end, now)))
        return try db.transaction {
            try db.run(
                "DELETE FROM time_entries WHERE origin = ? AND status = ? AND start_ts < ? AND end_ts > ?",
                [EntryOrigin.suggested.rawValue, EntryStatus.draft.rawValue, range.end, range.start])
            let occupied = try timeEntries(in: range, now: now).map {
                DateInterval(start: $0.start, end: max($0.start, $0.end ?? now))
            }
            let blocks = suggester.blocks(from: try activities(in: range, now: now), in: range, avoiding: occupied)
            return try blocks.map { block in
                var new = NewTimeEntry(start: block.start, end: block.end, projectID: block.label.projectID,
                                       categoryID: block.label.categoryID, title: block.title, origin: .suggested)
                new.status = .draft
                new.author = author
                return Suggestion(entry: try insertEntry(new, now: now), evidence: block.evidence)
            }
        }
    }

    // MARK: Summary

    /// Time totals under one key, in exact seconds.
    public struct TimeGroup: Codable, Equatable, Sendable {
        public var key: String
        public var seconds: Double
        public var billableSeconds: Double
    }

    /// Time entry totals over a range: claimed time, never observed time.
    public struct Summary: Codable, Equatable, Sendable {
        public var groups: [TimeGroup]
        /// The sum of the groups' seconds.
        public var seconds: Double
        public var billableSeconds: Double
        /// Billable ÷ total, or nil when there is no time.
        public var utilization: Double? { seconds > 0 ? billableSeconds / seconds : nil }

        init(groups: [TimeGroup]) {
            self.groups = groups
            seconds = groups.reduce(0) { $0 + $1.seconds }
            billableSeconds = groups.reduce(0) { $0 + $1.billableSeconds }
        }
    }

    /// The Summary of confirmed time entries (drafts optional), grouped by
    /// project, client, category or day.
    public func summary(
        in range: DateInterval, groupBy: GroupBy, filter: EntryFilter = EntryFilter(), includeDrafts: Bool = false,
        calendar: Calendar = .current, now: Date = Date()
    ) throws -> Summary {
        guard [.project, .client, .category, .day].contains(groupBy) else {
            throw StoreError.invalid("time entries can be grouped by project, client, category or day, not \(groupBy.rawValue)")
        }
        var filter = filter
        if !includeDrafts { filter.status = .confirmed }
        var totals: [String: (Double, Double)] = [:]
        for entry in try timeEntries(in: range, filter: filter, now: now) {
            let clipped = TimeAccounting.clip(start: entry.start, end: entry.end, to: range, now: now)
            let labels = TimeAccounting.Labels(project: entry.project, client: entry.client, category: entry.category)
            for (key, seconds) in TimeAccounting.pieces(of: clipped, groupBy: groupBy, labels: labels, calendar: calendar)
            where seconds > 0 {
                var t = totals[key] ?? (0, 0)
                t.0 += seconds
                if entry.billable { t.1 += seconds }
                totals[key] = t
            }
        }
        return Summary(groups: Self.sorted(totals.map { TimeGroup(key: $0.key, seconds: $0.value.0, billableSeconds: $0.value.1) },
                                           groupBy: groupBy))
    }

    // MARK: Unlogged time

    /// Unlogged time over a range: evidence for claiming, not claimed time.
    public struct UnloggedTime: Codable, Equatable, Sendable {
        public var groups: [TimeGroup]
        /// The sum of the groups' seconds.
        public var seconds: Double
        public var billableSeconds: Double

        init(groups: [TimeGroup]) {
            self.groups = groups
            seconds = groups.reduce(0) { $0 + $1.seconds }
            billableSeconds = groups.reduce(0) { $0 + $1.billableSeconds }
        }
    }

    /// Unlogged time: work a suggestion would offer to claim (buckets where one
    /// project dominates, agents excluded) minus confirmed time entries.
    public func unloggedTime(
        in range: DateInterval, groupBy: GroupBy, using suggester: EntrySuggester = EntrySuggester(),
        calendar: Calendar = .current, now: Date = Date()
    ) throws -> UnloggedTime {
        guard [.project, .client, .category, .day].contains(groupBy) else {
            throw StoreError.invalid("unlogged time can be grouped by project, client, category or day, not \(groupBy.rawValue)")
        }
        let range = DateInterval(start: range.start, end: max(range.start, min(range.end, now)))
        var filter = EntryFilter()
        filter.status = .confirmed
        let covered = try timeEntries(in: range, filter: filter, now: now).map {
            DateInterval(start: $0.start, end: max($0.start, $0.end ?? now))
        }
        let catalog = try catalog()
        var totals: [String: Double] = [:]
        for (bucket, label) in suggester.labeledBuckets(try activities(in: range, now: now), range: range) {
            let project = catalog.projects[label.projectID]
            let labels = TimeAccounting.Labels(
                project: project?.path ?? "#\(label.projectID)", client: project?.client,
                category: label.categoryID.flatMap { catalog.categories[$0]?.name })
            for piece in EntrySuggester.subtract(covered, from: bucket) {
                for (key, seconds) in TimeAccounting.pieces(of: piece, groupBy: groupBy, labels: labels, calendar: calendar) {
                    totals[key, default: 0] += seconds
                }
            }
        }
        return UnloggedTime(groups: Self.sorted(totals.map { TimeGroup(key: $0.key, seconds: $0.value, billableSeconds: 0) },
                                                groupBy: groupBy))
    }

    private static func sorted(_ rows: [TimeGroup], groupBy: GroupBy) -> [TimeGroup] {
        TimeAccounting.sorted(rows, groupBy: groupBy, key: \.key, seconds: \.seconds)
    }
}
