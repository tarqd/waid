import Foundation

/// Clients, projects, categories and rules: what time gets attributed to.
extension Store {
    // MARK: Lookup

    /// An in-memory snapshot of projects and categories for resolving ids to names.
    public struct Catalog {
        public var projects: [Int64: Project]
        public var categories: [Int64: Category]

        func resolve(_ activity: inout Activity, engine: RuleEngine) {
            activity.projectID = activity.assignedProjectID ?? engine.projectRule(for: activity)?.projectID
            activity.categoryID = activity.assignedCategoryID ?? engine.categoryRule(for: activity)?.categoryID
            let project = activity.projectID.flatMap { projects[$0] }
            activity.project = project?.path
            activity.category = activity.categoryID.flatMap { categories[$0]?.name }
            if let project, let clientID = project.clientID {
                activity.clientID = clientID
                activity.client = project.client
            } else if let match = engine.client(for: activity) {
                activity.clientID = match.id
                activity.client = match.name
            }
        }

        func resolve(_ entry: inout TimeEntry) {
            let project = entry.projectID.flatMap { projects[$0] }
            entry.project = project?.path
            entry.clientID = project?.clientID
            entry.client = project?.client
            entry.category = entry.categoryID.flatMap { categories[$0]?.name }
        }

        /// Billable unless the project isn't, or the category never is (e.g. presales).
        public func defaultBillable(projectID: Int64?, categoryID: Int64?) -> Bool {
            (projectID.flatMap { projects[$0]?.billable } ?? false)
                && (categoryID.flatMap { categories[$0]?.billable } ?? true)
        }
    }

    public func catalog() throws -> Catalog {
        Catalog(
            projects: Dictionary(uniqueKeysWithValues: try projects(includeClosed: true).map { ($0.id, $0) }),
            categories: Dictionary(uniqueKeysWithValues: try categories(includeArchived: true).map { ($0.id, $0) }))
    }

    // MARK: Clients

    public func clients(includeArchived: Bool = false) throws -> [Client] {
        try db.query("SELECT * FROM clients" + (includeArchived ? "" : " WHERE archived = 0") + " ORDER BY name")
            .map(Self.client)
    }

    public func client(named name: String) throws -> Client? {
        try db.query("SELECT * FROM clients WHERE name = ?", [name.trimmingCharacters(in: .whitespaces)]).first.map(Self.client)
    }

    public func requireClient(named name: String) throws -> Client {
        guard let client = try client(named: name) else {
            let known = try clients().map(\.name)
            throw StoreError.notFound("client \"\(name)\"" + (known.isEmpty ? "" : "; known clients: \(known.joined(separator: ", "))"))
        }
        return client
    }

    /// Returns the client with this name, creating it if needed, and adds any new domains.
    @discardableResult
    public func ensureClient(named name: String, addingDomains domains: [String] = []) throws -> Client {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalid("client name is empty") }
        let normalized = try domains.map(Self.normalizeDomain)
        if var existing = try client(named: trimmed) {
            let added = normalized.filter { !existing.domains.contains($0) }
            guard !added.isEmpty else { return existing }
            existing.domains += added
            try db.run("UPDATE clients SET domains = ? WHERE id = ?", [Self.encodeList(existing.domains), existing.id])
            return existing
        }
        try db.run("INSERT INTO clients(name, domains, created_ts) VALUES(?, ?, ?)",
                   [trimmed, Self.encodeList(normalized), Date()])
        return Client(id: db.lastInsertRowID, name: trimmed, domains: normalized, archived: false)
    }

    /// "https://www.Acme.com/x" -> "acme.com".
    static func normalizeDomain(_ raw: String) throws -> String {
        var d = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let url = URL(string: d), let host = url.host { d = host }
        if d.hasPrefix("www.") { d.removeFirst(4) }
        while d.hasSuffix("/") || d.hasSuffix(".") { d.removeLast() }
        guard d.contains("."), !d.contains("/"), !d.contains(" ") else {
            throw StoreError.invalid("\"\(raw)\" isn't a domain like acme.com")
        }
        return d
    }

    private static func client(_ row: Row) -> Client {
        Client(id: row.int("id")!, name: row.string("name")!, domains: decodeList(row.string("domains")),
               archived: row.int("archived") == 1)
    }

    // MARK: Projects

    public func projects(includeClosed: Bool = false, clientID: Int64? = nil) throws -> [Project] {
        var sql = "SELECT p.*, c.name AS client_name FROM projects p LEFT JOIN clients c ON c.id = p.client_id WHERE 1"
        var params: [SQLBindable] = []
        if !includeClosed { sql += " AND p.status != 'closed'" }
        if let clientID {
            sql += " AND p.client_id = ?"
            params.append(clientID)
        }
        return try db.query(sql + " ORDER BY c.name IS NOT NULL, c.name, p.name", params).map(Self.project)
    }

    public func project(id: Int64) throws -> Project? {
        try db.query("SELECT p.*, c.name AS client_name FROM projects p LEFT JOIN clients c ON c.id = p.client_id WHERE p.id = ?",
                     [id]).first.map(Self.project)
    }

    /// Splits "Acme / Phase 2" into ("Acme", "Phase 2"); a plain name has no client part.
    static func splitPath(_ ref: String) -> (client: String?, name: String) {
        let parts = ref.components(separatedBy: " / ")
        guard parts.count >= 2 else { return (nil, ref.trimmingCharacters(in: .whitespaces)) }
        return (parts[0].trimmingCharacters(in: .whitespaces),
                parts.dropFirst().joined(separator: " / ").trimmingCharacters(in: .whitespaces))
    }

    /// Finds a project by "Client / Name" or by plain name. A plain name
    /// matches an internal project first, then any engagement with that
    /// name if exactly one exists.
    public func findProject(_ ref: String) throws -> Project? {
        let (clientName, name) = Self.splitPath(ref)
        if let clientName {
            guard let client = try client(named: clientName) else { return nil }
            return try db.query(
                "SELECT p.*, c.name AS client_name FROM projects p JOIN clients c ON c.id = p.client_id WHERE p.client_id = ? AND p.name = ? COLLATE NOCASE",
                [client.id, name]).first.map(Self.project)
        }
        let matches = try db.query(
            "SELECT p.*, c.name AS client_name FROM projects p LEFT JOIN clients c ON c.id = p.client_id WHERE p.name = ? COLLATE NOCASE ORDER BY p.client_id IS NOT NULL",
            [name]).map(Self.project)
        if let own = matches.first(where: { $0.clientID == nil }) { return own }
        guard matches.count <= 1 else {
            throw StoreError.invalid("\"\(ref)\" is ambiguous; use one of: \(matches.map(\.path).joined(separator: ", "))")
        }
        return matches.first
    }

    public func requireProject(_ ref: String) throws -> Project {
        guard let project = try findProject(ref) else { throw StoreError.notFound("project \"\(ref)\"") }
        return project
    }

    /// Finds the project, or creates it: "Acme / Phase 2" creates a billable
    /// engagement (and the client if needed); a plain name creates an
    /// internal, non-billable project.
    @discardableResult
    public func ensureProject(_ ref: String) throws -> Project {
        if let existing = try findProject(ref) { return existing }
        let (clientName, name) = Self.splitPath(ref)
        let client = try clientName.map { try ensureClient(named: $0) }
        return try createProject(name: name, clientID: client?.id)
    }

    @discardableResult
    public func createProject(
        name: String, clientID: Int64? = nil, status: ProjectStatus = .active, billable: Bool? = nil,
        budgetHours: Double? = nil, startsOn: String? = nil, endsOn: String? = nil, color: String? = nil
    ) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" / ") else {
            throw StoreError.invalid("project name must be non-empty and can't contain \" / \"")
        }
        try Self.validate(budgetHours: budgetHours, startsOn: startsOn, endsOn: endsOn)
        do {
            try db.run(
                """
                INSERT INTO projects(name, client_id, status, billable, budget_hours, starts_on, ends_on, color, created_ts)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [trimmed, clientID, status.rawValue, billable ?? (clientID != nil), budgetHours, startsOn, endsOn, color, Date()])
        } catch let error as DatabaseError where error.message.contains("UNIQUE") {
            throw StoreError.invalid("a project named \"\(trimmed)\" already exists for that client")
        }
        return try project(id: db.lastInsertRowID)!
    }

    @discardableResult
    public func updateProject(id: Int64, _ changes: ProjectChanges) throws -> Project {
        guard var p = try project(id: id) else { throw StoreError.notFound("project \(id)") }
        if let name = changes.name { p.name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let clientID = changes.clientID { p.clientID = clientID }
        if let status = changes.status { p.status = status }
        if let billable = changes.billable { p.billable = billable }
        if let budget = changes.budgetHours { p.budgetHours = budget }
        if let startsOn = changes.startsOn { p.startsOn = startsOn }
        if let endsOn = changes.endsOn { p.endsOn = endsOn }
        if let color = changes.color { p.color = color }
        guard !p.name.isEmpty, !p.name.contains(" / ") else {
            throw StoreError.invalid("project name must be non-empty and can't contain \" / \"")
        }
        try Self.validate(budgetHours: p.budgetHours, startsOn: p.startsOn, endsOn: p.endsOn)
        do {
            try db.run(
                """
                UPDATE projects SET name = ?, client_id = ?, status = ?, billable = ?, budget_hours = ?,
                    starts_on = ?, ends_on = ?, color = ?
                WHERE id = ?
                """,
                [p.name, p.clientID, p.status.rawValue, p.billable, p.budgetHours, p.startsOn, p.endsOn, p.color, id])
        } catch let error as DatabaseError where error.message.contains("UNIQUE") {
            throw StoreError.invalid("a project named \"\(p.name)\" already exists for that client")
        }
        return try project(id: id)!
    }

    private static func validate(budgetHours: Double?, startsOn: String?, endsOn: String?) throws {
        if let budgetHours, budgetHours <= 0 { throw StoreError.invalid("budget_hours must be positive") }
        for date in [startsOn, endsOn].compactMap({ $0 }) {
            guard date.count == 10, TimeRange.parseDate(date) != nil else {
                throw StoreError.invalid("\"\(date)\" isn't a date like 2026-10-31")
            }
        }
        if let startsOn, let endsOn, endsOn < startsOn { throw StoreError.invalid("project ends before it starts") }
    }

    private static func project(_ row: Row) -> Project {
        Project(
            id: row.int("id")!, name: row.string("name")!, clientID: row.int("client_id"),
            client: row.string("client_name"),
            status: ProjectStatus(rawValue: row.string("status") ?? "") ?? .active,
            billable: row.int("billable") == 1, budgetHours: row.double("budget_hours"),
            startsOn: row.string("starts_on"), endsOn: row.string("ends_on"), color: row.string("color"))
    }

    // MARK: Categories

    public func categories(includeArchived: Bool = false) throws -> [Category] {
        try db.query("SELECT * FROM categories" + (includeArchived ? "" : " WHERE archived = 0") + " ORDER BY name")
            .map(Self.category)
    }

    public func category(named name: String) throws -> Category? {
        try db.query("SELECT * FROM categories WHERE name = ?", [name.trimmingCharacters(in: .whitespaces)]).first
            .map(Self.category)
    }

    /// Categories are a small, deliberate list, so unknown names are an error
    /// rather than silently created.
    public func requireCategory(named name: String) throws -> Category {
        guard let category = try category(named: name) else {
            let known = try categories().map(\.name)
            throw StoreError.notFound("category \"\(name)\"; known categories: \(known.joined(separator: ", "))")
        }
        return category
    }

    @discardableResult
    public func createCategory(named name: String, billable: Bool = true, color: String? = nil) throws -> Category {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalid("category name is empty") }
        if let existing = try category(named: trimmed) { return existing }
        try db.run("INSERT INTO categories(name, billable, color, created_ts) VALUES(?, ?, ?, ?)",
                   [trimmed, billable, color, Date()])
        return Category(id: db.lastInsertRowID, name: trimmed, billable: billable, color: color, archived: false)
    }

    private static func category(_ row: Row) -> Category {
        Category(id: row.int("id")!, name: row.string("name")!, billable: row.int("billable") == 1,
                 color: row.string("color"), archived: row.int("archived") == 1)
    }

    // MARK: Rules

    public func rules() throws -> [Rule] {
        try db.query("SELECT * FROM rules ORDER BY priority DESC, id ASC").compactMap { row in
            guard let field = RuleField(rawValue: row.string("field") ?? ""),
                  let op = RuleOp(rawValue: row.string("op") ?? "")
            else { return nil }
            return Rule(
                id: row.int("id")!, projectID: row.int("project_id"), categoryID: row.int("category_id"),
                field: field, op: op, pattern: row.string("pattern")!, priority: Int(row.int("priority") ?? 0))
        }
    }

    @discardableResult
    public func addRule(
        projectID: Int64? = nil, categoryID: Int64? = nil, field: RuleField, op: RuleOp, pattern: String,
        priority: Int = 0
    ) throws -> Rule {
        guard projectID != nil || categoryID != nil else {
            throw StoreError.invalid("a rule must set a project, a category, or both")
        }
        if op == .regex {
            do { _ = try NSRegularExpression(pattern: pattern) } catch {
                throw StoreError.invalid("regex \"\(pattern)\" does not compile: \(error.localizedDescription)")
            }
        }
        try db.run(
            "INSERT INTO rules(project_id, category_id, field, op, pattern, priority, created_ts) VALUES(?, ?, ?, ?, ?, ?, ?)",
            [projectID, categoryID, field.rawValue, op.rawValue, pattern, priority, Date()])
        return Rule(id: db.lastInsertRowID, projectID: projectID, categoryID: categoryID, field: field, op: op,
                    pattern: pattern, priority: priority)
    }

    public func deleteRule(id: Int64) throws {
        guard try db.run("DELETE FROM rules WHERE id = ?", [id]) > 0 else { throw StoreError.notFound("rule \(id)") }
    }

    // MARK: Helpers

    static func encodeList(_ list: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(list)) ?? Data("[]".utf8), as: UTF8.self)
    }

    static func decodeList(_ json: String?) -> [String] {
        json.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }
}
