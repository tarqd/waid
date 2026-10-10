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

    static let migrations: [String] = [
        """
        CREATE TABLE projects(
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            color TEXT,
            archived INTEGER NOT NULL DEFAULT 0,
            created_ts REAL NOT NULL
        );
        CREATE TABLE activities(
            id INTEGER PRIMARY KEY,
            start_ts REAL NOT NULL,
            end_ts REAL,
            source TEXT NOT NULL,
            bundle_id TEXT,
            app_name TEXT,
            title TEXT,
            url TEXT,
            path TEXT,
            external_id TEXT,
            project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
            note TEXT,
            meta TEXT
        );
        CREATE INDEX activities_start ON activities(start_ts);
        CREATE UNIQUE INDEX activities_external ON activities(source, external_id)
            WHERE external_id IS NOT NULL;
        CREATE TABLE rules(
            id INTEGER PRIMARY KEY,
            project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            field TEXT NOT NULL,
            op TEXT NOT NULL,
            pattern TEXT NOT NULL,
            priority INTEGER NOT NULL DEFAULT 0,
            created_ts REAL NOT NULL
        );
        CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """,
        // Split claimed time (time entries) from observed time (activities).
        """
        ALTER TABLE projects ADD COLUMN parent_id INTEGER REFERENCES projects(id) ON DELETE SET NULL;
        ALTER TABLE activities ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0;
        CREATE TABLE time_entries(
            id INTEGER PRIMARY KEY,
            start_ts REAL NOT NULL,
            end_ts REAL,
            project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
            title TEXT,
            notes TEXT,
            tags TEXT NOT NULL DEFAULT '[]',
            billable INTEGER NOT NULL DEFAULT 0,
            origin TEXT NOT NULL,
            author TEXT NOT NULL DEFAULT 'user',
            status TEXT NOT NULL DEFAULT 'confirmed',
            created_ts REAL NOT NULL,
            updated_ts REAL NOT NULL
        );
        CREATE INDEX time_entries_start ON time_entries(start_ts);
        INSERT INTO time_entries(start_ts, end_ts, project_id, notes, origin, created_ts, updated_ts)
            SELECT start_ts, end_ts, project_id, note, source, start_ts, COALESCE(end_ts, start_ts)
            FROM activities WHERE source IN ('timer', 'manual');
        DELETE FROM activities WHERE source IN ('timer', 'manual');
        """,
        // Professional-services model: clients, projects that are either
        // client engagements or internal, and categories (kind of work) as a
        // second, independent dimension. Parents of the old project tree
        // become clients.
        """
        CREATE TABLE clients(
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            domains TEXT NOT NULL DEFAULT '[]',
            archived INTEGER NOT NULL DEFAULT 0,
            created_ts REAL NOT NULL
        );
        INSERT INTO clients(name, created_ts)
            SELECT p.name, p.created_ts FROM projects p
            WHERE EXISTS (SELECT 1 FROM projects c WHERE c.parent_id = p.id);
        CREATE TABLE projects_new(
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
        );
        INSERT INTO projects_new(id, name, client_id, status, billable, color, created_ts)
            SELECT p.id, p.name,
                (SELECT c.id FROM clients c JOIN projects parent ON parent.name = c.name WHERE parent.id = p.parent_id),
                CASE WHEN p.archived THEN 'closed' ELSE 'active' END,
                p.parent_id IS NOT NULL, p.color, p.created_ts
            FROM projects p;
        DROP TABLE projects;
        ALTER TABLE projects_new RENAME TO projects;
        CREATE UNIQUE INDEX projects_client_name ON projects(COALESCE(client_id, 0), name COLLATE NOCASE);

        CREATE TABLE categories(
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE COLLATE NOCASE,
            billable INTEGER NOT NULL DEFAULT 1,
            color TEXT,
            archived INTEGER NOT NULL DEFAULT 0,
            created_ts REAL NOT NULL
        );
        INSERT INTO categories(name, billable, created_ts) VALUES
            ('Presales', 0, 0), ('Implementation', 1, 0), ('Meetings', 1, 0), ('Admin', 0, 0);
        ALTER TABLE activities ADD COLUMN category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL;
        ALTER TABLE time_entries ADD COLUMN category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL;

        CREATE TABLE rules_new(
            id INTEGER PRIMARY KEY,
            project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE,
            category_id INTEGER REFERENCES categories(id) ON DELETE CASCADE,
            field TEXT NOT NULL,
            op TEXT NOT NULL,
            pattern TEXT NOT NULL,
            priority INTEGER NOT NULL DEFAULT 0,
            created_ts REAL NOT NULL,
            CHECK (project_id IS NOT NULL OR category_id IS NOT NULL)
        );
        INSERT INTO rules_new(id, project_id, field, op, pattern, priority, created_ts)
            SELECT id, project_id, field, op, pattern, priority, created_ts FROM rules;
        DROP TABLE rules;
        ALTER TABLE rules_new RENAME TO rules;
        """,
        // Zone history (ADR-0001): which time zone you were in, and from when.
        """
        CREATE TABLE zone_history(
            id INTEGER PRIMARY KEY,
            zone TEXT NOT NULL,
            effective_ts REAL NOT NULL
        );
        CREATE INDEX zone_history_effective ON zone_history(effective_ts);
        """,
    ]

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
        guard version < Self.migrations.count else { return }
        // Table rebuilds need foreign keys off (they can't be toggled inside a
        // transaction); integrity is checked before committing instead.
        try db.execute("PRAGMA foreign_keys=OFF")
        defer { try? db.execute("PRAGMA foreign_keys=ON") }
        try db.transaction {
            for (index, sql) in Self.migrations.enumerated() where index >= version {
                try db.execute(sql)
            }
            if let violation = try db.query("PRAGMA foreign_key_check").first {
                throw StoreError.invalid("migration broke a foreign key: \(violation.columns)")
            }
            try db.execute("PRAGMA user_version = \(Self.migrations.count)")
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

    // MARK: Activities

    @discardableResult
    public func insertActivity(
        start: Date, end: Date?, source: String, sample: ActivitySample = ActivitySample(),
        projectID: Int64? = nil, note: String? = nil
    ) throws -> Int64 {
        try db.run(
            """
            INSERT INTO activities(start_ts, end_ts, source, bundle_id, app_name, title, url, path, project_id, note)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [start, end, source, sample.bundleID, sample.appName, sample.title, sample.url, sample.path, projectID, note])
        return db.lastInsertRowID
    }

    public func setEnd(activityID: Int64, end: Date) throws {
        try db.run("UPDATE activities SET end_ts = ? WHERE id = ?", [end, activityID])
    }

    /// Inserts or refreshes a span keyed by `(source, externalID)`. Used by
    /// importers so re-running them is idempotent. A project assigned by the
    /// user is never overwritten.
    public func upsertExternal(
        source: String, externalID: String, start: Date, end: Date,
        title: String?, path: String?, meta: String? = nil
    ) throws {
        try db.run(
            """
            INSERT INTO activities(start_ts, end_ts, source, external_id, title, path, meta)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source, external_id) WHERE external_id IS NOT NULL DO UPDATE SET
                start_ts = excluded.start_ts, end_ts = excluded.end_ts,
                title = excluded.title, path = excluded.path, meta = excluded.meta
            """,
            [start, end, source, externalID, title, path, meta])
    }

    /// Explicitly assigns spans to a project and/or category, overriding
    /// rules. nil leaves a dimension alone; .some(nil) clears the override.
    /// Returns rows changed.
    @discardableResult
    public func assign(activityIDs: [Int64], projectID: Int64?? = nil, categoryID: Int64?? = nil) throws -> Int {
        try db.transaction {
            try activityIDs.reduce(0) { total, id in
                var changed = 0
                if let projectID {
                    changed = try db.run("UPDATE activities SET project_id = ? WHERE id = ?", [projectID, id])
                }
                if let categoryID {
                    changed = try db.run("UPDATE activities SET category_id = ? WHERE id = ?", [categoryID, id])
                }
                return total + changed
            }
        }
    }

    public func activity(id: Int64) throws -> Activity? {
        try db.query("SELECT * FROM activities WHERE id = ?", [id]).first.map(Self.activity)
    }

    /// Hides spans from queries and reports, or unhides them. Returns rows changed.
    @discardableResult
    public func setHidden(activityIDs: [Int64], hidden: Bool) throws -> Int {
        try db.transaction {
            try activityIDs.reduce(0) { total, id in
                total + (try db.run("UPDATE activities SET hidden = ? WHERE id = ?", [hidden, id]))
            }
        }
    }

    public func latestActivity(source: String) throws -> Activity? {
        try db.query(
            "SELECT * FROM activities WHERE source = ? ORDER BY start_ts DESC LIMIT 1", [source]
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
        var sql = "SELECT * FROM activities WHERE start_ts < ? AND COALESCE(end_ts, ?) > ?"
        var params: [SQLBindable] = [range.end, now, range.start]
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

    private static func activity(_ row: Row) -> Activity {
        Activity(
            id: row.int("id")!, start: row.date("start_ts")!, end: row.date("end_ts"),
            source: row.string("source")!, bundleID: row.string("bundle_id"), appName: row.string("app_name"),
            title: row.string("title"), url: row.string("url"), path: row.string("path"),
            externalID: row.string("external_id"), assignedProjectID: row.int("project_id"),
            assignedCategoryID: row.int("category_id"), note: row.string("note"), meta: row.string("meta"), hidden: row.int("hidden") == 1)
    }

    // MARK: Summaries

    public enum GroupBy: String, CaseIterable, Sendable {
        case project, client, category, app, source, day
    }

    public struct SummaryRow: Codable, Equatable, Sendable {
        public var key: String
        /// Seconds per source. Sources are reported separately because they
        /// overlap in wall-clock time and must not be summed blindly.
        public var secondsBySource: [String: Double]
    }

    public func summary(
        in range: DateInterval, groupBy: GroupBy, filter: ActivityFilter = ActivityFilter(),
        calendar: Calendar = .current, now: Date = Date()
    ) throws -> [SummaryRow] {
        var totals: [String: [String: Double]] = [:]
        for activity in try activities(in: range, filter: filter, now: now) {
            let clipped = TimeAccounting.clip(start: activity.start, end: activity.end, to: range, now: now)
            let labels = TimeAccounting.Labels(project: activity.project, client: activity.client,
                                               category: activity.category, app: activity.appName, source: activity.source)
            for (key, seconds) in TimeAccounting.pieces(of: clipped, groupBy: groupBy, labels: labels, calendar: calendar)
            where seconds > 0 {
                totals[key, default: [:]][activity.source, default: 0] += seconds
            }
        }
        return TimeAccounting.sorted(
            totals.map { SummaryRow(key: $0.key, secondsBySource: $0.value) }, groupBy: groupBy,
            key: \.key, seconds: { $0.secondsBySource.values.reduce(0, +) })
    }
}

extension Store {
    static let noProject = TimeAccounting.noProject
    static let noClient = TimeAccounting.noClient
    static let noCategory = TimeAccounting.noCategory
}
