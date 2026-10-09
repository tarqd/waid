import Foundation

public enum StoreError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case invalid(String)

    public var description: String {
        switch self {
        case .notFound(let what): return "not found: \(what)"
        case .invalid(let why): return "invalid: \(why)"
        }
    }
}

/// All persistent state lives in one local SQLite file. There is no server.
public final class Store {
    public let db: Database

    private static let migrations: [String] = [
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
        """
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
        try db.transaction {
            for (index, sql) in Self.migrations.enumerated() where index >= version {
                try db.execute(sql)
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

    // MARK: Projects

    public func projects(includeArchived: Bool = false) throws -> [Project] {
        let sql = "SELECT * FROM projects" + (includeArchived ? "" : " WHERE archived = 0") + " ORDER BY name"
        return try db.query(sql).map(Self.project)
    }

    public func project(named name: String) throws -> Project? {
        try db.query("SELECT * FROM projects WHERE name = ?", [name]).first.map(Self.project)
    }

    public func project(id: Int64) throws -> Project? {
        try db.query("SELECT * FROM projects WHERE id = ?", [id]).first.map(Self.project)
    }

    /// Returns the existing project with this name, or creates it.
    @discardableResult
    public func ensureProject(named name: String, color: String? = nil) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalid("project name is empty") }
        if let existing = try project(named: trimmed) { return existing }
        try db.run("INSERT INTO projects(name, color, created_ts) VALUES(?, ?, ?)", [trimmed, color, Date()])
        return Project(id: db.lastInsertRowID, name: trimmed, color: color, archived: false)
    }

    public func requireProject(named name: String) throws -> Project {
        guard let project = try project(named: name) else { throw StoreError.notFound("project \"\(name)\"") }
        return project
    }

    private static func project(_ row: Row) -> Project {
        Project(
            id: row.int("id")!, name: row.string("name")!, color: row.string("color"),
            archived: row.int("archived") == 1)
    }

    // MARK: Rules

    public func rules() throws -> [Rule] {
        try db.query("SELECT * FROM rules ORDER BY priority DESC, id ASC").compactMap { row in
            guard let field = RuleField(rawValue: row.string("field") ?? ""),
                  let op = RuleOp(rawValue: row.string("op") ?? "")
            else { return nil }
            return Rule(
                id: row.int("id")!, projectID: row.int("project_id")!, field: field, op: op,
                pattern: row.string("pattern")!, priority: Int(row.int("priority") ?? 0))
        }
    }

    @discardableResult
    public func addRule(projectID: Int64, field: RuleField, op: RuleOp, pattern: String, priority: Int = 0) throws -> Rule {
        if op == .regex {
            do { _ = try NSRegularExpression(pattern: pattern) } catch {
                throw StoreError.invalid("regex \"\(pattern)\" does not compile: \(error.localizedDescription)")
            }
        }
        try db.run(
            "INSERT INTO rules(project_id, field, op, pattern, priority, created_ts) VALUES(?, ?, ?, ?, ?, ?)",
            [projectID, field.rawValue, op.rawValue, pattern, priority, Date()])
        return Rule(id: db.lastInsertRowID, projectID: projectID, field: field, op: op, pattern: pattern, priority: priority)
    }

    public func deleteRule(id: Int64) throws {
        guard try db.run("DELETE FROM rules WHERE id = ?", [id]) > 0 else { throw StoreError.notFound("rule \(id)") }
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

    /// Explicitly assigns spans to a project (or clears with nil). Returns rows changed.
    @discardableResult
    public func assign(activityIDs: [Int64], projectID: Int64?) throws -> Int {
        try db.transaction {
            try activityIDs.reduce(0) { total, id in
                total + (try db.run("UPDATE activities SET project_id = ? WHERE id = ?", [projectID, id]))
            }
        }
    }

    public func activity(id: Int64) throws -> Activity? {
        try db.query("SELECT * FROM activities WHERE id = ?", [id]).first.map(Self.activity)
    }

    public func runningTimer() throws -> Activity? {
        try db.query(
            "SELECT * FROM activities WHERE source = ? AND end_ts IS NULL ORDER BY start_ts DESC LIMIT 1",
            [Source.timer]
        ).first.map(Self.activity)
    }

    public func latestActivity(source: String) throws -> Activity? {
        try db.query(
            "SELECT * FROM activities WHERE source = ? ORDER BY start_ts DESC LIMIT 1", [source]
        ).first.map(Self.activity)
    }

    public struct ActivityFilter {
        public var sources: [String]?
        public var projectID: Int64?
        public var uncategorizedOnly = false
        public var text: String?
        public var limit: Int?
        public init() {}
    }

    /// Spans overlapping `range`, with the effective project resolved.
    public func activities(in range: DateInterval, filter: ActivityFilter = ActivityFilter(), now: Date = Date()) throws -> [Activity] {
        var sql = "SELECT * FROM activities WHERE start_ts < ? AND COALESCE(end_ts, ?) > ?"
        var params: [SQLBindable] = [range.end, now, range.start]
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
        let engine = RuleEngine(rules: try rules())
        let names = Dictionary(uniqueKeysWithValues: try projects(includeArchived: true).map { ($0.id, $0.name) })
        var result: [Activity] = []
        for row in try db.query(sql, params) {
            var activity = Self.activity(row)
            activity.projectID = activity.assignedProjectID ?? engine.projectID(for: activity)
            activity.project = activity.projectID.flatMap { names[$0] }
            if filter.uncategorizedOnly && activity.projectID != nil { continue }
            if let projectID = filter.projectID, activity.projectID != projectID { continue }
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
            note: row.string("note"), meta: row.string("meta"))
    }

    // MARK: Summaries

    public enum GroupBy: String, CaseIterable, Sendable {
        case project, app, source, day
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
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        for activity in try activities(in: range, filter: filter, now: now) {
            let clipped = DateInterval(
                start: max(activity.start, range.start),
                end: max(max(activity.start, range.start), min(activity.end ?? now, range.end)))
            // Day grouping splits spans that cross midnight.
            var pieces: [(String, TimeInterval)] = []
            switch groupBy {
            case .project: pieces = [(activity.project ?? "(uncategorized)", clipped.duration)]
            case .app: pieces = [(activity.appName ?? activity.source, clipped.duration)]
            case .source: pieces = [(activity.source, clipped.duration)]
            case .day:
                var cursor = clipped.start
                while cursor < clipped.end {
                    let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor))!
                    let pieceEnd = min(dayEnd, clipped.end)
                    pieces.append((dayFormatter.string(from: cursor), pieceEnd.timeIntervalSince(cursor)))
                    cursor = pieceEnd
                }
            }
            for (key, seconds) in pieces where seconds > 0 {
                totals[key, default: [:]][activity.source, default: 0] += seconds
            }
        }
        return totals
            .map { SummaryRow(key: $0.key, secondsBySource: $0.value) }
            .sorted {
                groupBy == .day ? $0.key < $1.key
                    : $0.secondsBySource.values.reduce(0, +) > $1.secondsBySource.values.reduce(0, +)
            }
    }
}
