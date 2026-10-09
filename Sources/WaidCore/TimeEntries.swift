import Foundation

extension Store {
    public func timeEntry(id: Int64) throws -> TimeEntry? {
        guard let row = try db.query("SELECT * FROM time_entries WHERE id = ?", [id]).first else { return nil }
        return Self.timeEntry(row, paths: try projectPaths())
    }

    public func requireTimeEntry(id: Int64) throws -> TimeEntry {
        guard let entry = try timeEntry(id: id) else { throw StoreError.notFound("time entry \(id)") }
        return entry
    }

    public struct EntryFilter {
        public var status: EntryStatus?
        public var projectID: Int64?
        public var text: String?
        public init() {}
    }

    /// Entries overlapping `range`, oldest first.
    public func timeEntries(in range: DateInterval, filter: EntryFilter = EntryFilter(), now: Date = Date()) throws -> [TimeEntry] {
        var sql = "SELECT * FROM time_entries WHERE start_ts < ? AND COALESCE(end_ts, MAX(?, start_ts)) > ?"
        var params: [SQLBindable] = [range.end, now, range.start]
        if let status = filter.status {
            sql += " AND status = ?"
            params.append(status.rawValue)
        }
        if let projectID = filter.projectID {
            sql += " AND project_id = ?"
            params.append(projectID)
        }
        if let text = filter.text, !text.isEmpty {
            sql += " AND (title LIKE ? OR notes LIKE ? OR tags LIKE ?)"
            params += Array(repeating: "%\(text)%" as SQLBindable, count: 3)
        }
        let paths = try projectPaths()
        return try db.query(sql + " ORDER BY start_ts", params).map { Self.timeEntry($0, paths: paths) }
    }

    public func runningEntry() throws -> TimeEntry? {
        guard let row = try db.query("SELECT * FROM time_entries WHERE end_ts IS NULL ORDER BY start_ts DESC LIMIT 1").first
        else { return nil }
        return Self.timeEntry(row, paths: try projectPaths())
    }

    @discardableResult
    public func createEntry(_ new: NewTimeEntry, now: Date = Date()) throws -> TimeEntry {
        try db.transaction { try insertEntry(new, now: now) }
    }

    /// Validates and inserts without opening a transaction, for callers that
    /// already hold one.
    func insertEntry(_ new: NewTimeEntry, now: Date) throws -> TimeEntry {
        try validate(start: new.start, end: new.end, excluding: nil, now: now)
        try db.run(
            """
            INSERT INTO time_entries(start_ts, end_ts, project_id, title, notes, tags, billable, origin, author, status,
                                     created_ts, updated_ts)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [new.start, new.end, new.projectID, new.title, new.notes, Self.encodeTags(new.tags), new.billable,
             new.origin.rawValue, new.author, new.status.rawValue, now, now])
        return try requireTimeEntry(id: db.lastInsertRowID)
    }

    @discardableResult
    public func updateEntry(id: Int64, _ changes: TimeEntryChanges, now: Date = Date()) throws -> TimeEntry {
        try db.transaction {
            var entry = try requireTimeEntry(id: id)
            if let start = changes.start { entry.start = start }
            if let end = changes.end { entry.end = end }
            if let projectID = changes.projectID { entry.projectID = projectID }
            if let title = changes.title { entry.title = title }
            if let notes = changes.notes { entry.notes = notes }
            if let tags = changes.tags { entry.tags = tags }
            if let billable = changes.billable { entry.billable = billable }
            if let status = changes.status { entry.status = status }
            try validate(start: entry.start, end: entry.end, excluding: id, now: now)
            try db.run(
                """
                UPDATE time_entries SET start_ts = ?, end_ts = ?, project_id = ?, title = ?, notes = ?, tags = ?,
                    billable = ?, status = ?, updated_ts = ?
                WHERE id = ?
                """,
                [entry.start, entry.end, entry.projectID, entry.title, entry.notes, Self.encodeTags(entry.tags),
                 entry.billable, entry.status.rawValue, now, id])
            return try requireTimeEntry(id: id)
        }
    }

    public func deleteEntry(id: Int64) throws {
        guard try db.run("DELETE FROM time_entries WHERE id = ?", [id]) > 0 else {
            throw StoreError.notFound("time entry \(id)")
        }
    }

    /// Sets the status of several entries at once. Returns rows changed.
    @discardableResult
    public func setStatus(entryIDs: [Int64], _ status: EntryStatus, now: Date = Date()) throws -> Int {
        try db.transaction {
            try entryIDs.reduce(0) { total, id in
                total + (try db.run("UPDATE time_entries SET status = ?, updated_ts = ? WHERE id = ?",
                                    [status.rawValue, now, id]))
            }
        }
    }

    /// Starts a running entry, first stopping any running one at `now`.
    public func startTimer(
        projectID: Int64?, title: String? = nil, notes: String? = nil, author: String = "user", now: Date = Date()
    ) throws -> (started: TimeEntry, stopped: TimeEntry?) {
        try db.transaction {
            var stopped: TimeEntry?
            if let running = try runningEntry() {
                try db.run("UPDATE time_entries SET end_ts = ?, updated_ts = ? WHERE id = ?",
                           [max(now, running.start), now, running.id])
                stopped = try requireTimeEntry(id: running.id)
            }
            var new = NewTimeEntry(start: now, end: nil, projectID: projectID, title: title, origin: .timer)
            new.notes = notes
            new.author = author
            return (try insertEntry(new, now: now), stopped)
        }
    }

    /// Stops the running entry, if any, and returns it.
    @discardableResult
    public func stopTimer(now: Date = Date()) throws -> TimeEntry? {
        try db.transaction {
            guard let running = try runningEntry() else { return nil }
            try db.run("UPDATE time_entries SET end_ts = ?, updated_ts = ? WHERE id = ?",
                       [max(now, running.start), now, running.id])
            return try requireTimeEntry(id: running.id)
        }
    }

    /// Entries may not overlap; a running entry counts as ending now.
    private func validate(start: Date, end: Date?, excluding: Int64?, now: Date) throws {
        if let end, end <= start { throw StoreError.invalid("entry must end after it starts") }
        if end == nil {
            if start > now { throw StoreError.invalid("a running entry can't start in the future") }
            if let running = try runningEntry(), running.id != excluding {
                throw StoreError.overlap("time entry \(running.id) is already running; stop it first")
            }
        }
        let effectiveEnd = end ?? now
        let conflicts = try db.query(
            "SELECT * FROM time_entries WHERE id != ? AND start_ts < ? AND COALESCE(end_ts, MAX(?, start_ts)) > ?",
            [excluding ?? -1, effectiveEnd, now, start])
        guard conflicts.isEmpty else {
            let paths = try projectPaths()
            let list = conflicts.map { Self.timeEntry($0, paths: paths) }.map { e in
                "#\(e.id) \(Self.describe(e.start))–\(e.end.map(Self.describe) ?? "running") \(e.project ?? "(no project)")"
            }
            throw StoreError.overlap("entries can't overlap; conflicts with \(list.joined(separator: ", "))")
        }
    }

    private static func describe(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: date)
    }

    private static func encodeTags(_ tags: [String]) -> String {
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return String(decoding: (try? JSONEncoder().encode(cleaned)) ?? Data("[]".utf8), as: UTF8.self)
    }

    static func timeEntry(_ row: Row, paths: [Int64: String]) -> TimeEntry {
        let tags = row.string("tags").flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        let projectID = row.int("project_id")
        return TimeEntry(
            id: row.int("id")!, start: row.date("start_ts")!, end: row.date("end_ts"), projectID: projectID,
            title: row.string("title"), notes: row.string("notes"), tags: tags, billable: row.int("billable") == 1,
            origin: EntryOrigin(rawValue: row.string("origin") ?? "") ?? .manual,
            author: row.string("author") ?? "user",
            status: EntryStatus(rawValue: row.string("status") ?? "") ?? .confirmed,
            project: projectID.flatMap { paths[$0] })
    }
}
