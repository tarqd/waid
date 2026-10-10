import Foundation

public enum StoreError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case invalid(String)
    case overlap(String)

    public var description: String {
        switch self {
        case .notFound(let what): return "not found: \(what)"
        case .invalid(let why): return "invalid: \(why)"
        case .overlap(let why): return "overlap: \(why)"
        }
    }
}

/// All persistent state lives in one local SQLite file. There is no server.
public final class Store {
    public let db: Database
    /// The zone of the writing process: what rows with no zone of their own
    /// are stamped with (ADR-0002). The system zone at the time of writing,
    /// unless set.
    public var processZone: TimeZone {
        get { fixedZone ?? .current }
        set { fixedZone = newValue }
    }
    private var fixedZone: TimeZone?

    /// The zone a new row is stamped with, and the local dates of its first
    /// and last instants there (see `localDates(start:end:in:)`). Today that
    /// is `zone`, else `processZone`; ADR-0002's fallback chain (the zone of
    /// the nearest earlier observation) belongs here.
    func stamp(start: Date, end: Date? = nil, zone: TimeZone?) -> (zone: TimeZone, startDate: String, endDate: String?) {
        let zone = zone ?? processZone
        let dates = Self.localDates(start: start, end: end, in: zone)
        return (zone, dates.start, dates.end)
    }

    /// The schema version a database created by `schema` carries. Earlier
    /// versions came from the migration history before observations, which
    /// waid never shipped and does not migrate.
    static let schemaVersion = 5

    /// The whole schema, created at once in a new database. Every table is
    /// STRICT (SQLite 3.37+), and observations enforce their own rules.
    static let schema = """
        CREATE TABLE clients(
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            domains TEXT NOT NULL DEFAULT '[]',
            archived INTEGER NOT NULL DEFAULT 0,
            created_ts REAL NOT NULL
        ) STRICT;

        -- A project with a client is an engagement; one without is internal.
        CREATE TABLE projects(
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            client_id INTEGER REFERENCES clients(id) ON DELETE SET NULL,
            status TEXT NOT NULL DEFAULT 'active',
            billable INTEGER NOT NULL DEFAULT 0,
            budget_hours REAL,
            starts_on TEXT,
            ends_on TEXT,
            color TEXT,
            created_ts REAL NOT NULL
        ) STRICT;
        CREATE UNIQUE INDEX projects_client_name ON projects(COALESCE(client_id, 0), name COLLATE NOCASE);

        -- The kind of work, independent of what it's for.
        CREATE TABLE categories(
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            billable INTEGER NOT NULL DEFAULT 1,
            color TEXT,
            archived INTEGER NOT NULL DEFAULT 0,
            created_ts REAL NOT NULL
        ) STRICT;
        INSERT INTO categories(name, billable, created_ts) VALUES
            ('Presales', 0, 0), ('Implementation', 1, 0), ('Meetings', 1, 0), ('Admin', 0, 0);

        CREATE TABLE rules(
            id INTEGER PRIMARY KEY,
            project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE,
            category_id INTEGER REFERENCES categories(id) ON DELETE CASCADE,
            field TEXT NOT NULL,
            op TEXT NOT NULL,
            pattern TEXT NOT NULL,
            priority INTEGER NOT NULL DEFAULT 0,
            created_ts REAL NOT NULL,
            CHECK (project_id IS NOT NULL OR category_id IS NOT NULL)
        ) STRICT;

        -- Observations (GLOSSARY.md): stretches of the focus, active and
        -- locked streams, each with the zone it happened in and its local
        -- date (ADR-0002). end_ts is never NULL: an open observation's end
        -- is its last heartbeat.
        CREATE TABLE observations(
            id INTEGER PRIMARY KEY,
            stream TEXT NOT NULL CHECK (stream IN ('focus', 'active', 'locked')),
            source TEXT NOT NULL,
            start_ts REAL NOT NULL,
            end_ts REAL NOT NULL,
            open INTEGER NOT NULL DEFAULT 0 CHECK (open IN (0, 1)),
            zone TEXT NOT NULL,
            local_date TEXT NOT NULL,
            bundle_id TEXT,
            app_name TEXT,
            title TEXT,
            url TEXT,
            path TEXT,
            external_id TEXT,
            project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
            category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
            hidden INTEGER NOT NULL DEFAULT 0 CHECK (hidden IN (0, 1)),
            note TEXT,
            meta TEXT,
            CHECK (end_ts >= start_ts),
            -- What was in front, and an importer's id, only describe focus.
            CHECK (stream = 'focus' OR (bundle_id IS NULL AND app_name IS NULL AND title IS NULL
                                        AND url IS NULL AND path IS NULL AND external_id IS NULL))
        ) STRICT;
        CREATE INDEX observations_stream_start ON observations(stream, start_ts);
        CREATE INDEX observations_local_date ON observations(local_date);
        CREATE UNIQUE INDEX observations_external ON observations(source, external_id)
            WHERE external_id IS NOT NULL;
        -- At most one observation per stream and source is still being recorded.
        CREATE UNIQUE INDEX observations_open ON observations(stream, source) WHERE open = 1;

        -- No two observations of one stream and source overlap. Imported
        -- agent segments may overlap each other: sessions run in parallel.
        -- SQLite triggers can't share a body, so the insert and update
        -- triggers repeat the same WHEN EXISTS; keep the two in sync.
        CREATE TRIGGER observations_no_overlap_insert BEFORE INSERT ON observations
        WHEN EXISTS (
            SELECT 1 FROM observations o
            WHERE o.stream = NEW.stream AND o.source = NEW.source
              AND o.start_ts < NEW.end_ts AND NEW.start_ts < o.end_ts
              AND (o.external_id IS NULL OR NEW.external_id IS NULL))
        BEGIN
            SELECT RAISE(ABORT, 'observation overlaps another in the same stream and source');
        END;
        CREATE TRIGGER observations_no_overlap_update
        BEFORE UPDATE OF stream, source, start_ts, end_ts, external_id ON observations
        WHEN EXISTS (
            SELECT 1 FROM observations o
            WHERE o.id != NEW.id AND o.stream = NEW.stream AND o.source = NEW.source
              AND o.start_ts < NEW.end_ts AND NEW.start_ts < o.end_ts
              AND (o.external_id IS NULL OR NEW.external_id IS NULL))
        BEGIN
            SELECT RAISE(ABORT, 'observation overlaps another in the same stream and source');
        END;

        -- A closed observation is evidence: its time, identity and payload
        -- are fixed, though overrides and meta stay editable. Imported rows
        -- (with an external_id) stay upsertable.
        CREATE TRIGGER observations_closed_fixed BEFORE UPDATE ON observations
        WHEN OLD.open = 0 AND OLD.external_id IS NULL AND (
            NEW.open IS NOT OLD.open OR NEW.external_id IS NOT OLD.external_id
            OR NEW.start_ts IS NOT OLD.start_ts OR NEW.end_ts IS NOT OLD.end_ts
            OR NEW.stream IS NOT OLD.stream OR NEW.source IS NOT OLD.source
            OR NEW.zone IS NOT OLD.zone OR NEW.local_date IS NOT OLD.local_date
            OR NEW.bundle_id IS NOT OLD.bundle_id OR NEW.app_name IS NOT OLD.app_name
            OR NEW.title IS NOT OLD.title OR NEW.url IS NOT OLD.url OR NEW.path IS NOT OLD.path)
        BEGIN
            SELECT RAISE(ABORT, 'a closed observation''s time, identity and payload can''t change');
        END;

        -- Claimed time. zone is where it happened; start_date and end_date
        -- are its local dates there, end_date NULL while running.
        CREATE TABLE time_entries(
            id INTEGER PRIMARY KEY,
            start_ts REAL NOT NULL,
            end_ts REAL,
            zone TEXT NOT NULL,
            start_date TEXT NOT NULL,
            end_date TEXT,
            project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
            category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
            title TEXT,
            notes TEXT,
            tags TEXT NOT NULL DEFAULT '[]',
            billable INTEGER NOT NULL DEFAULT 0,
            origin TEXT NOT NULL CHECK (origin IN ('timer', 'manual', 'from_activities', 'suggested', 'away')),
            author TEXT NOT NULL DEFAULT 'user',
            status TEXT NOT NULL DEFAULT 'confirmed',
            created_ts REAL NOT NULL,
            updated_ts REAL NOT NULL,
            CHECK ((end_ts IS NULL) = (end_date IS NULL))
        ) STRICT;
        CREATE INDEX time_entries_start ON time_entries(start_ts);

        -- Zone history (ADR-0001), superseded by ADR-0002; still read for
        -- range selection until stored local dates replace it.
        CREATE TABLE zone_history(
            id INTEGER PRIMARY KEY,
            zone TEXT NOT NULL,
            effective_ts REAL NOT NULL
        ) STRICT;
        CREATE INDEX zone_history_effective ON zone_history(effective_ts);

        -- Bookkeeping and settings.
        CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
        INSERT INTO kv(key, value) VALUES('idle_threshold_seconds', '180');
        """

    public init(path: String) throws {
        db = try Database(path: path)
        try migrate()
    }

    /// Default location: `$WAID_DB`, else the platform's per-user data directory.
    public static func defaultPath() throws -> String {
        if let env = ProcessInfo.processInfo.environment["WAID_DB"], !env.isEmpty { return env }
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/waid")
        #else
        let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        let base = (xdg.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share"))
            .appendingPathComponent("waid")
        #endif
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("waid.sqlite").path
    }

    private func migrate() throws {
        let version = Int(try db.query("PRAGMA user_version").first?.int("user_version") ?? 0)
        if version == Self.schemaVersion { return }
        if version > Self.schemaVersion {
            throw StoreError.invalid(
                "the database has schema version \(version), from a newer version of waid than this one (\(Self.schemaVersion)); upgrade waid to open it")
        }
        guard version == 0 else {
            throw StoreError.invalid(
                "the database has schema version \(version), from before observations, and can't be migrated; move it aside to start fresh")
        }
        try db.transaction {
            try db.execute(Self.schema)
            try db.execute("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    // MARK: Key-value

    public func value(forKey key: String) throws -> String? {
        try db.query("SELECT value FROM kv WHERE key = ?", [key]).first?.string("value")
    }

    public func setValue(_ value: String, forKey key: String) throws {
        try db.run(
            "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [key, value])
    }

    // MARK: Observations

    /// Inserts a focus observation stamped with `zone` (else `processZone`)
    /// and the local date of its start there. With no `end` it is open, its
    /// end the heartbeat at `start`, until `close(activityID:end:)`; with an
    /// `end` it is closed.
    @discardableResult
    public func insertActivity(
        start: Date, end: Date?, source: String, sample: ActivitySample = ActivitySample(),
        projectID: Int64? = nil, note: String? = nil, zone: TimeZone? = nil
    ) throws -> Int64 {
        let stamped = stamp(start: start, zone: zone)
        try db.run(
            """
            INSERT INTO observations(stream, source, start_ts, end_ts, open, zone, local_date,
                                     bundle_id, app_name, title, url, path, project_id, note)
            VALUES('focus', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [source, start, end ?? start, end == nil, stamped.zone.identifier, stamped.startDate,
             sample.bundleID, sample.appName, sample.title, sample.url, sample.path, projectID, note])
        return db.lastInsertRowID
    }

    /// Moves an open observation's heartbeat. A closed one can't be changed.
    public func setEnd(activityID: Int64, end: Date) throws {
        try db.run("UPDATE observations SET end_ts = ? WHERE id = ?", [end, activityID])
    }

    /// Closes an open observation at `end`; after this its time is fixed.
    public func close(activityID: Int64, end: Date) throws {
        try db.run("UPDATE observations SET end_ts = ?, open = 0 WHERE id = ? AND open = 1", [end, activityID])
    }

    /// Closes every observation still open at its last heartbeat, as after a
    /// restart. Returns how many were closed.
    @discardableResult
    public func closeOpenObservations() throws -> Int {
        try db.run("UPDATE observations SET open = 0 WHERE open = 1")
    }

    /// Inserts or refreshes a focus observation keyed by `(source,
    /// externalID)` and returns its id. Used by importers so re-running them
    /// is idempotent. A project assigned by the user is never overwritten.
    @discardableResult
    public func upsertExternal(
        source: String, externalID: String, start: Date, end: Date,
        title: String?, path: String?, meta: String? = nil, zone: TimeZone? = nil
    ) throws -> Int64 {
        let stamped = stamp(start: start, zone: zone)
        let row = try db.query(
            """
            INSERT INTO observations(stream, source, start_ts, end_ts, zone, local_date, external_id, title, path, meta)
            VALUES('focus', ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source, external_id) WHERE external_id IS NOT NULL DO UPDATE SET
                start_ts = excluded.start_ts, end_ts = excluded.end_ts,
                zone = excluded.zone, local_date = excluded.local_date,
                title = excluded.title, path = excluded.path, meta = excluded.meta
            RETURNING id
            """,
            [source, start, end, stamped.zone.identifier, stamped.startDate, externalID, title, path, meta])
        return row[0].int("id")!
    }

    /// Explicitly assigns observations to a project and/or category, overriding
    /// rules. nil leaves a dimension alone; .some(nil) clears the override.
    /// Returns rows changed.
    @discardableResult
    public func assign(activityIDs: [Int64], projectID: Int64?? = nil, categoryID: Int64?? = nil) throws -> Int {
        try db.transaction {
            try activityIDs.reduce(0) { total, id in
                var changed = 0
                if let projectID {
                    changed = try db.run("UPDATE observations SET project_id = ? WHERE id = ?", [projectID, id])
                }
                if let categoryID {
                    changed = try db.run("UPDATE observations SET category_id = ? WHERE id = ?", [categoryID, id])
                }
                return total + changed
            }
        }
    }

    public func activity(id: Int64) throws -> Activity? {
        try db.query("SELECT * FROM observations WHERE stream = 'focus' AND id = ?", [id]).first.map(Self.activity)
    }

    /// Hides observations from queries and reports, or unhides them. Returns rows changed.
    @discardableResult
    public func setHidden(activityIDs: [Int64], hidden: Bool) throws -> Int {
        try db.transaction {
            try activityIDs.reduce(0) { total, id in
                total + (try db.run("UPDATE observations SET hidden = ? WHERE id = ?", [hidden, id]))
            }
        }
    }

    public func latestActivity(source: String) throws -> Activity? {
        try db.query(
            "SELECT * FROM observations WHERE stream = 'focus' AND source = ? ORDER BY start_ts DESC LIMIT 1", [source]
        ).first.map(Self.activity)
    }

    public struct ActivityFilter {
        public var sources: [String]?
        public var projectID: Int64?
        public var clientID: Int64?
        public var categoryID: Int64?
        /// Only activities with no project.
        public var uncategorizedOnly = false
        public var text: String?
        public var limit: Int?
        public var includeHidden = false
        public init() {}
    }

    /// Spans overlapping `range`, with project, category and client resolved.
    public func activities(in range: DateInterval, filter: ActivityFilter = ActivityFilter(), now: Date = Date()) throws -> [Activity] {
        var sql = "SELECT * FROM observations WHERE stream = 'focus' AND start_ts < ? AND end_ts > ?"
        var params: [SQLBindable] = [range.end, range.start]
        if !filter.includeHidden { sql += " AND hidden = 0" }
        if let sources = filter.sources, !sources.isEmpty {
            sql += " AND source IN (" + sources.map { _ in "?" }.joined(separator: ",") + ")"
            params += sources.map { $0 as SQLBindable }
        }
        if let text = filter.text, !text.isEmpty {
            sql += " AND (title LIKE ? OR app_name LIKE ? OR url LIKE ? OR path LIKE ? OR note LIKE ?)"
            let like = "%\(text)%"
            params += Array(repeating: like as SQLBindable, count: 5)
        }
        sql += " ORDER BY start_ts"
        let engine = RuleEngine(rules: try rules(), clients: try clients(includeArchived: true))
        let lookup = try catalog()
        var result: [Activity] = []
        for row in try db.query(sql, params) {
            var activity = Self.activity(row)
            lookup.resolve(&activity, engine: engine)
            if filter.uncategorizedOnly && activity.projectID != nil { continue }
            if let projectID = filter.projectID, activity.projectID != projectID { continue }
            if let clientID = filter.clientID, activity.clientID != clientID { continue }
            if let categoryID = filter.categoryID, activity.categoryID != categoryID { continue }
            result.append(activity)
            if let limit = filter.limit, result.count >= limit { break }
        }
        return result
    }

    /// Spans with time on `range`'s local dates (or in its instants), oldest
    /// first, with project, category and client resolved. When a local date
    /// repeats, spans in the gap between its stretches are left out.
    public func activities(
        in range: ReportRange, filter: ActivityFilter = ActivityFilter(), calendar: Calendar = .current, now: Date = Date()
    ) throws -> [Activity] {
        try activities(overlapping: try intervals(range, calendar: calendar), filter: filter, now: now)
    }

    /// Spans overlapping any of `intervals`, oldest first.
    func activities(overlapping intervals: [DateInterval], filter: ActivityFilter, now: Date) throws -> [Activity] {
        guard let hull = TimeAccounting.hull(intervals) else { return [] }
        var unlimited = filter
        unlimited.limit = nil
        let spans = try activities(in: hull, filter: unlimited, now: now).filter {
            TimeAccounting.overlaps(start: $0.start, end: $0.end, intervals, now: now)
        }
        return filter.limit.map { Array(spans.prefix($0)) } ?? spans
    }

    private static func activity(_ row: Row) -> Activity {
        Activity(
            id: row.int("id")!, start: row.date("start_ts")!, end: row.date("end_ts"),
            source: row.string("source")!, bundleID: row.string("bundle_id"), appName: row.string("app_name"),
            title: row.string("title"), url: row.string("url"), path: row.string("path"),
            externalID: row.string("external_id"), assignedProjectID: row.int("project_id"),
            assignedCategoryID: row.int("category_id"), note: row.string("note"), meta: row.string("meta"),
            hidden: row.int("hidden") == 1, open: row.int("open") == 1, zone: row.string("zone")!,
            localDate: row.string("local_date")!)
    }

    // MARK: Evidence

    public enum GroupBy: String, CaseIterable, Sendable {
        case project, client, category, app, source, day
    }

    /// Evidence under one key: observed activity time per source.
    public struct EvidenceRow: Codable, Equatable, Sendable {
        public var key: String
        /// Seconds per source. Sources are reported separately because they
        /// overlap in wall-clock time and must not be summed blindly.
        public var secondsBySource: [String: Double]
    }

    /// Evidence: activity totals per source, to help write time entries.
    /// Observed time, never claimed time, so never summed across sources.
    public func evidence(
        in range: ReportRange, groupBy: GroupBy, filter: ActivityFilter = ActivityFilter(),
        calendar: Calendar = .current, now: Date = Date()
    ) throws -> [EvidenceRow] {
        struct Key: Hashable { var key: String; var source: String }
        let dates = try localDates(fallback: calendar)
        let intervals = dates.intervals(range)
        var tally = TimeAccounting.Tally<Key>()
        for activity in try activities(overlapping: intervals, filter: filter, now: now) {
            let keys = TimeAccounting.GroupKeys(project: activity.project, client: activity.client,
                                                category: activity.category, app: activity.appName, source: activity.source)
            for clipped in TimeAccounting.clip(start: activity.start, end: activity.end, to: intervals, now: now) {
                tally.add(clipped, groupBy: groupBy, keys: keys, dates: dates) { Key(key: $0, source: activity.source) }
            }
        }
        var rows: [String: [String: Double]] = [:]
        for (key, total) in tally.totals { rows[key.key, default: [:]][key.source] = total.seconds }
        return TimeAccounting.sorted(
            rows.map { EvidenceRow(key: $0.key, secondsBySource: $0.value) }, groupBy: groupBy,
            key: \.key, seconds: { $0.secondsBySource.values.reduce(0, +) })
    }
}
