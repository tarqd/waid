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
        var used: [Int64: (confirmed: Double, billable: Double, draft: Double)] = [:]
        for entry in try timeEntries(in: TimeAccounting.allTime, now: now) {
            guard let id = entry.projectID else { continue }
            let hours = TimeAccounting.clip(start: entry.start, end: entry.end, to: TimeAccounting.allTime, now: now).duration / 3600
            var t = used[id] ?? (0, 0, 0)
            if entry.status == .draft {
                t.draft += hours
            } else {
                t.confirmed += hours
                if entry.billable { t.billable += hours }
            }
            used[id] = t
        }
        return projects.map { p in
            let t = used[p.id] ?? (0, 0, 0)
            return BudgetRow(
                project: p.path, client: p.client, status: p.status, budgetHours: p.budgetHours,
                usedHours: t.confirmed, billableHours: t.billable, draftHours: t.draft,
                remainingHours: p.budgetHours.map { $0 - t.confirmed },
                burn: p.budgetHours.map { t.confirmed / $0 }, endsOn: p.endsOn)
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

    /// One row per day × project × category, from confirmed entries.
    public func timesheet(
        in range: ReportRange, filter: EntryFilter = EntryFilter(), includeDrafts: Bool = false,
        calendar: Calendar = .current, now: Date = Date()
    ) throws -> [TimesheetRow] {
        var filter = filter
        if !includeDrafts { filter.status = .confirmed }
        struct Key: Hashable { var date: String; var projectID: Int64?; var categoryID: Int64? }
        let dates = try localDates(fallback: calendar)
        let intervals = dates.intervals(range)
        var rows: [Key: TimesheetRow] = [:]
        for entry in try TimeAccounting.hull(intervals).map({ try timeEntries(in: $0, filter: filter, now: now) }) ?? [] {
            let pieces = TimeAccounting.clip(start: entry.start, end: entry.end, to: intervals, now: now).flatMap(dates.split)
            for (date, seconds) in pieces where seconds > 0 {
                let key = Key(date: date, projectID: entry.projectID, categoryID: entry.categoryID)
                var row = rows[key] ?? TimesheetRow(
                    date: date, client: entry.client, project: entry.project, category: entry.category,
                    hours: 0, billableHours: 0, notes: [])
                row.hours += seconds / 3600
                if entry.billable { row.billableHours += seconds / 3600 }
                for note in [entry.title, entry.notes].compactMap({ $0 }) where !note.isEmpty && !row.notes.contains(note) {
                    row.notes.append(note)
                }
                rows[key] = row
            }
        }
        return rows.values.sorted {
            ($0.date, $0.client ?? "", $0.project ?? "", $0.category ?? "")
                < ($1.date, $1.client ?? "", $1.project ?? "", $1.category ?? "")
        }
    }

    /// The timesheet over exact instants.
    public func timesheet(
        in range: DateInterval, filter: EntryFilter = EntryFilter(), includeDrafts: Bool = false,
        calendar: Calendar = .current, now: Date = Date()
    ) throws -> [TimesheetRow] {
        try timesheet(in: .instants(range), filter: filter, includeDrafts: includeDrafts, calendar: calendar, now: now)
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
