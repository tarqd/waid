import Foundation

/// Professional-services reports: budget burn and timesheets.
extension Store {
    public struct BudgetRow: Codable, Equatable, Sendable {
        public var project: String
        public var client: String?
        public var status: ProjectStatus
        public var budgetHours: Double?
        /// Confirmed entry hours on the project, all time.
        public var usedHours: Double
        public var billableHours: Double
        /// Draft hours not yet confirmed, which would add to `usedHours`.
        public var draftHours: Double
        public var remainingHours: Double?
        /// usedHours / budgetHours.
        public var burn: Double?
        public var endsOn: String?
    }

    /// Hours used against budget for each open project (or the given ones),
    /// most-burned first. Projects without a budget are included only when asked for by id.
    public func budgetStatus(projectIDs: [Int64]? = nil, now: Date = Date()) throws -> [BudgetRow] {
        let projects = try projectIDs.map { try $0.compactMap { try project(id: $0) } }
            ?? self.projects().filter { $0.budgetHours != nil }
        var confirmed = TimeAccounting.Tally<Int64>(), drafts = TimeAccounting.Tally<Int64>()
        for entry in try timeEntries(in: TimeAccounting.allTime, now: now) {
            guard let id = entry.projectID else { continue }
            let seconds = TimeAccounting.clip(start: entry.start, end: entry.end, to: TimeAccounting.allTime, now: now).duration
            if entry.status == .draft {
                drafts.add(seconds, to: id)
            } else {
                confirmed.add(seconds, to: id, billable: entry.billable)
            }
        }
        return projects.map { p in
            let used = confirmed[p.id].seconds / 3600
            return BudgetRow(
                project: p.path, client: p.client, status: p.status, budgetHours: p.budgetHours,
                usedHours: used, billableHours: confirmed[p.id].billableSeconds / 3600,
                draftHours: drafts[p.id].seconds / 3600,
                remainingHours: p.budgetHours.map { $0 - used },
                burn: p.budgetHours.map { used / $0 }, endsOn: p.endsOn)
        }.sorted { ($0.burn ?? -1) > ($1.burn ?? -1) }
    }

    public struct TimesheetRow: Codable, Equatable, Sendable {
        public var date: String
        public var client: String?
        public var project: String?
        public var category: String?
        public var hours: Double
        public var billableHours: Double
        /// Entry titles and notes for the day, deduplicated: the billing narrative.
        public var notes: [String]
    }

    /// One row per day × project × category, from confirmed entries (drafts
    /// optional; a status filter, when given, decides instead).
    public func timesheet(
        in range: ReportRange, filter: EntryFilter = EntryFilter(), includeDrafts: Bool = false,
        calendar: Calendar = .current, now: Date = Date()
    ) throws -> [TimesheetRow] {
        struct Key: Hashable { var date: String; var projectID: Int64?; var categoryID: Int64? }
        let dates = try localDates(fallback: calendar)
        let intervals = dates.intervals(range)
        var tally = TimeAccounting.Tally<Key>()
        var rows: [Key: TimesheetRow] = [:]
        for entry in try timeEntries(overlapping: intervals, filter: filter.counting(drafts: includeDrafts), now: now) {
            let keys = TimeAccounting.GroupKeys(project: entry.project, client: entry.client, category: entry.category)
            func key(_ date: String) -> Key { Key(date: date, projectID: entry.projectID, categoryID: entry.categoryID) }
            for clipped in TimeAccounting.clip(start: entry.start, end: entry.end, to: intervals, now: now) {
                tally.add(clipped, groupBy: .day, keys: keys, dates: dates, billable: entry.billable, as: key)
                for (date, _) in dates.split(clipped) {
                    var row = rows[key(date)] ?? TimesheetRow(
                        date: date, client: entry.client, project: entry.project, category: entry.category,
                        hours: 0, billableHours: 0, notes: [])
                    for note in [entry.title, entry.notes].compactMap({ $0 }) where !note.isEmpty && !row.notes.contains(note) {
                        row.notes.append(note)
                    }
                    rows[key(date)] = row
                }
            }
        }
        for (key, total) in tally.totals {
            rows[key]?.hours = total.seconds / 3600
            rows[key]?.billableHours = total.billableSeconds / 3600
        }
        return rows.values.filter { $0.hours > 0 }.sorted {
            ($0.date, $0.client ?? "", $0.project ?? "", $0.category ?? "")
                < ($1.date, $1.client ?? "", $1.project ?? "", $1.category ?? "")
        }
    }

    /// CSV in the shape timesheet/PSA tools import: one row per day, project and category.
    public static func csv(_ rows: [TimesheetRow]) -> String {
        func field(_ s: String?) -> String {
            let s = s ?? ""
            return s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let projectName = { (row: TimesheetRow) -> String? in
            guard let project = row.project else { return nil }
            return row.client.map { _ in splitPath(project).name } ?? project
        }
        var lines = ["date,client,project,category,hours,billable_hours,notes"]
        for row in rows {
            lines.append([
                row.date, field(row.client), field(projectName(row)), field(row.category),
                String(format: "%.2f", row.hours), String(format: "%.2f", row.billableHours),
                field(row.notes.joined(separator: "; ")),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
