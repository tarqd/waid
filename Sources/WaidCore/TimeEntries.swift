import Foundation

extension Store {
    public func timeEntry(id: Int64) throws -> TimeEntry? {
        guard let row = try db.query("SELECT * FROM time_entries WHERE id = ?", [id]).first else { return nil }
        return Self.timeEntry(row, catalog: try catalog())
    }

    public func requireTimeEntry(id: Int64) throws -> TimeEntry {
        guard let entry = try timeEntry(id: id) else { throw StoreError.notFound("time entry \(id)") }
        return entry
    }

    public struct EntryFilter {
        public var status: EntryStatus?
        public var projectID: Int64?
        public var clientID: Int64?
        public var categoryID: Int64?
        /// Substring match on title or notes.
        public var text: String?
        public init() {}

        /// Confirmed entries only, unless a status is asked for or drafts are included.
        func counting(drafts includeDrafts: Bool) -> EntryFilter {
            var filter = self
            if !includeDrafts && filter.status == nil { filter.status = .confirmed }
            return filter
        }
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
        if let clientID = filter.clientID {
            sql += " AND project_id IN (SELECT id FROM projects WHERE client_id = ?)"
            params.append(clientID)
        }
        if let categoryID = filter.categoryID {
            sql += " AND category_id = ?"
            params.append(categoryID)
        }
        if let text = filter.text, !text.isEmpty {
            sql += " AND (title LIKE ? OR notes LIKE ?)"
            params += Array(repeating: "%\(text)%" as SQLBindable, count: 2)
        }
        let catalog = try catalog()
        return try db.query(sql + " ORDER BY start_ts", params).map { Self.timeEntry($0, catalog: catalog) }
    }

    /// Entries with time on `range`'s local dates (or in its instants), oldest
    /// first. When a local date repeats, entries in the gap between its
    /// stretches are left out.
    public func timeEntries(
        in range: ReportRange, filter: EntryFilter = EntryFilter(), calendar: Calendar = .current, now: Date = Date()
    ) throws -> [TimeEntry] {
        try timeEntries(overlapping: try intervals(range, calendar: calendar), filter: filter, now: now)
    }

    /// Entries overlapping any of `intervals`, oldest first.
    func timeEntries(overlapping intervals: [DateInterval], filter: EntryFilter, now: Date) throws -> [TimeEntry] {
        guard let hull = TimeAccounting.hull(intervals) else { return [] }
        return try timeEntries(in: hull, filter: filter, now: now).filter {
            TimeAccounting.overlaps(start: $0.start, end: $0.end, intervals, now: now)
        }
    }

    public func runningEntry() throws -> TimeEntry? {
        guard let row = try db.query("SELECT * FROM time_entries WHERE end_ts IS NULL ORDER BY start_ts DESC LIMIT 1").first
        else { return nil }
        return Self.timeEntry(row, catalog: try catalog())
    }

    @discardableResult
    public func createEntry(_ new: NewTimeEntry, now: Date = Date()) throws -> TimeEntry {
        try db.transaction { try insertEntry(new, now: now) }
    }

    /// Validates and inserts without opening a transaction, for callers that
    /// already hold one.
    func insertEntry(_ new: NewTimeEntry, now: Date) throws -> TimeEntry {
        try validate(start: new.start, end: new.end, excluding: nil, now: now)
        let billable = try new.billable ?? catalog().defaultBillable(projectID: new.projectID, categoryID: new.categoryID)
        let stamped = try stamp(start: new.start, end: new.end, zone: new.zone)
        try db.run(
            """
            INSERT INTO time_entries(start_ts, end_ts, zone, start_date, end_date, project_id, category_id, title, notes,
                                     tags, billable, origin, author, status, created_ts, updated_ts)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [new.start, new.end, stamped.zone.identifier, stamped.startDate, stamped.endDate, new.projectID,
             new.categoryID, new.title, new.notes, Self.encodeTags(new.tags), billable, new.origin.rawValue,
             new.author, new.status.rawValue, now, now])
        return try requireTimeEntry(id: db.lastInsertRowID)
    }

    @discardableResult
    public func updateEntry(id: Int64, _ changes: TimeEntryChanges, now: Date = Date()) throws -> TimeEntry {
        try db.transaction {
            var entry = try requireTimeEntry(id: id)
            if let start = changes.start { entry.start = start }
            if let end = changes.end { entry.end = end }
            if let projectID = changes.projectID { entry.projectID = projectID }
            if let categoryID = changes.categoryID { entry.categoryID = categoryID }
            if changes.billable == nil && (changes.projectID != nil || changes.categoryID != nil) {
                entry.billable = try catalog().defaultBillable(projectID: entry.projectID, categoryID: entry.categoryID)
            }
            if let title = changes.title { entry.title = title }
            if let notes = changes.notes { entry.notes = notes }
            if let tags = changes.tags { entry.tags = tags }
            if let billable = changes.billable { entry.billable = billable }
            if let status = changes.status { entry.status = status }
            if let zone = changes.zone { entry.zone = zone.identifier }
            try validate(start: entry.start, end: entry.end, excluding: id, now: now)
            let dates = Self.localDates(start: entry.start, end: entry.end, in: zone(of: entry))
            try db.run(
                """
                UPDATE time_entries SET start_ts = ?, end_ts = ?, zone = ?, start_date = ?, end_date = ?, project_id = ?,
                    category_id = ?, title = ?, notes = ?, tags = ?, billable = ?, status = ?, updated_ts = ?
                WHERE id = ?
                """,
                [entry.start, entry.end, entry.zone, dates.start, dates.end, entry.projectID, entry.categoryID, entry.title,
                 entry.notes, Self.encodeTags(entry.tags), entry.billable, entry.status.rawValue, now, id])
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
        projectID: Int64?, categoryID: Int64? = nil, title: String? = nil, notes: String? = nil,
        author: String = "user", now: Date = Date()
    ) throws -> (started: TimeEntry, stopped: TimeEntry?) {
        try db.transaction {
            var stopped: TimeEntry?
            if let running = try runningEntry() {
                stopped = try stop(running, now: now)
            }
            var new = NewTimeEntry(start: now, end: nil, projectID: projectID, categoryID: categoryID, title: title,
                                   origin: .timer)
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
            return try stop(running, now: now)
        }
    }

    /// Ends a running entry at `now`, or at its start if that is later.
    private func stop(_ running: TimeEntry, now: Date) throws -> TimeEntry {
        let end = max(now, running.start)
        let endDate = Self.localDates(start: running.start, end: end, in: zone(of: running)).end
        try db.run("UPDATE time_entries SET end_ts = ?, end_date = ?, updated_ts = ? WHERE id = ?",
                   [end, endDate, now, running.id])
        return try requireTimeEntry(id: running.id)
    }

    private func zone(of entry: TimeEntry) -> TimeZone {
        TimeZone(identifier: entry.zone) ?? processZone
    }

    /// The local dates of a span's first and last instants in `zone`. A span
    /// ending exactly at a local midnight has no time on the date that starts
    /// there, so its last date is the one before. No end, no last date.
    static func localDates(start: Date, end: Date?, in zone: TimeZone) -> (start: String, end: String?) {
        let first = LocalDate(start, in: zone)
        guard let end else { return (first.description, nil) }
        var last = LocalDate(end, in: zone)
        if end > start && last.start(in: zone) == end { last = last.adding(days: -1) }
        return (first.description, max(first, last).description)
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
            let catalog = try catalog()
            let list = conflicts.map { Self.timeEntry($0, catalog: catalog) }.map { e in
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
        encodeList(tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static func timeEntry(_ row: Row, catalog: Catalog) -> TimeEntry {
        var entry = TimeEntry(
            id: row.int("id")!, start: row.date("start_ts")!, end: row.date("end_ts"), projectID: row.int("project_id"),
            categoryID: row.int("category_id"), title: row.string("title"), notes: row.string("notes"),
            tags: decodeList(row.string("tags")), billable: row.int("billable") == 1,
            origin: EntryOrigin(rawValue: row.string("origin") ?? "") ?? .manual,
            author: row.string("author") ?? "user",
            status: EntryStatus(rawValue: row.string("status") ?? "") ?? .confirmed,
            zone: row.string("zone")!, startDate: row.string("start_date")!, endDate: row.string("end_date"))
        catalog.resolve(&entry)
        return entry
    }
}
