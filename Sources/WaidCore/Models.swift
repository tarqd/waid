import Foundation

/// One observation of what is in front of the user, produced by a capture backend.
public struct ActivitySample: Codable, Equatable, Sendable {
    public var bundleID: String?
    public var appName: String?
    public var title: String?
    public var url: String?
    public var path: String?
    /// Seconds since the last keyboard/mouse input.
    public var idleSeconds: Double

    public init(
        bundleID: String? = nil, appName: String? = nil, title: String? = nil,
        url: String? = nil, path: String? = nil, idleSeconds: Double = 0
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.url = url
        self.path = path
        self.idleSeconds = idleSeconds
    }
}

/// Where an observed span came from. Sources overlap by design: an agent can
/// be working in a repo while the user is in a browser.
public enum Source {
    public static let window = "window"
    public static let agentPrefix = "agent:"

    public static func agent(_ name: String) -> String { agentPrefix + name }
}

/// A focus observation: a window in front, an agent session. Activities are
/// evidence; they are categorized but not edited.
public struct Activity: Codable, Equatable, Sendable {
    public var id: Int64
    public var start: Date
    public var end: Date?
    public var source: String
    public var bundleID: String?
    public var appName: String?
    public var title: String?
    public var url: String?
    public var path: String?
    public var externalID: String?
    /// Project explicitly assigned to this span; overrides rules.
    public var assignedProjectID: Int64?
    /// Category explicitly assigned to this span; overrides rules.
    public var assignedCategoryID: Int64?
    public var note: String?
    public var meta: String?
    /// Kept out of queries and reports (e.g. private browsing).
    public var hidden: Bool = false
    /// Still being recorded; `end` is its last heartbeat.
    public var open: Bool = false
    /// The IANA zone it happened in, and its local date there ("yyyy-MM-dd").
    public var zone: String
    public var localDate: String

    /// Filled in by queries: resolved from assignment, rules, or (for the
    /// client) a client's domains.
    public var projectID: Int64?
    public var project: String?
    public var categoryID: Int64?
    public var category: String?
    public var clientID: Int64?
    public var client: String?

    public func duration(now: Date = Date()) -> TimeInterval {
        TimeAccounting.end(start: start, end: end, now: now).timeIntervalSince(start)
    }
}

/// Who the work is for. Domains (acme.com) attribute matching URLs to the client.
public struct Client: Codable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var domains: [String]
    public var archived: Bool
}

public enum ProjectStatus: String, Codable, CaseIterable, Sendable {
    /// Presales: the deal isn't won yet.
    case prospect
    case active
    case closed
}

/// What the work is for. A project with a client is an engagement (usually
/// with an hours budget); one without is internal.
public struct Project: Codable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var clientID: Int64?
    /// Filled in on load.
    public var client: String?
    public var status: ProjectStatus
    /// Whether time on this project is billable by default.
    public var billable: Bool
    public var budgetHours: Double?
    /// Local dates, "yyyy-MM-dd".
    public var startsOn: String?
    public var endsOn: String?
    public var color: String?

    /// "Acme / Phase 2", or just the name for an internal project.
    public var path: String { client.map { "\($0) / \(name)" } ?? name }
}

public struct ProjectChanges: Sendable {
    public var name: String?
    public var clientID: Int64??
    public var status: ProjectStatus?
    public var billable: Bool?
    public var budgetHours: Double??
    public var startsOn: String??
    public var endsOn: String??
    public var color: String??
    public init() {}
}

/// The kind of work (presales, implementation, meetings), independent of
/// what it's for.
public struct Category: Codable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    /// false means never billable (e.g. presales), even on a billable project.
    public var billable: Bool
    public var color: String?
    public var archived: Bool
}

public enum RuleField: String, Codable, CaseIterable, Sendable {
    case bundleID = "bundle_id"
    case appName = "app_name"
    case title
    case url
    case path
    case source
}

public enum RuleOp: String, Codable, CaseIterable, Sendable {
    case contains
    case equals
    case prefix
    case regex
}

public struct Rule: Codable, Equatable, Sendable {
    public var id: Int64
    /// A rule sets the project, the category, or both. Each is resolved
    /// independently, so "app is Zoom -> Meetings" and "title contains Acme
    /// -> Acme" combine.
    public var projectID: Int64?
    public var categoryID: Int64?
    public var field: RuleField
    public var op: RuleOp
    public var pattern: String
    /// Higher priority rules are evaluated first; ties go to the older rule.
    public var priority: Int
}

public enum EntryOrigin: String, Codable, CaseIterable, Sendable {
    case timer
    case manual
    /// Made from a stretch of activities the user selected.
    case fromActivities = "from_activities"
    /// Drafted by the suggester.
    case suggested
    /// Claimed from a stretch when you were away.
    case away
}

public enum EntryStatus: String, Codable, CaseIterable, Sendable {
    /// A suggestion; excluded from entry reports until confirmed.
    case draft
    case confirmed
}

/// What the user claims they did: the unit of reporting and billing.
/// Entries never overlap each other.
public struct TimeEntry: Codable, Equatable, Sendable {
    public var id: Int64
    public var start: Date
    /// nil while the timer is running.
    public var end: Date?
    public var projectID: Int64?
    public var categoryID: Int64?
    public var title: String?
    public var notes: String?
    public var tags: [String]
    public var billable: Bool
    public var origin: EntryOrigin
    /// "user", or "agent:<client>" for entries written over MCP.
    public var author: String
    public var status: EntryStatus
    /// The IANA zone it happened in, and its first and last local dates
    /// there ("yyyy-MM-dd"); `endDate` is nil while running.
    public var zone: String
    public var startDate: String
    public var endDate: String?

    /// Filled in by queries.
    public var project: String?
    public var clientID: Int64?
    public var client: String?
    public var category: String?

    public func duration(now: Date = Date()) -> TimeInterval {
        TimeAccounting.end(start: start, end: end, now: now).timeIntervalSince(start)
    }
}

public struct NewTimeEntry: Sendable {
    public var start: Date
    public var end: Date?
    public var projectID: Int64?
    public var categoryID: Int64?
    public var title: String?
    public var notes: String?
    public var tags: [String] = []
    /// nil: derive from the project and category.
    public var billable: Bool?
    public var origin: EntryOrigin
    public var author = "user"
    public var status = EntryStatus.confirmed

    public init(
        start: Date, end: Date?, projectID: Int64? = nil, categoryID: Int64? = nil, title: String? = nil,
        origin: EntryOrigin
    ) {
        self.start = start
        self.end = end
        self.projectID = projectID
        self.categoryID = categoryID
        self.title = title
        self.origin = origin
    }
}

/// Partial update. Double optionals distinguish "leave alone" (nil) from
/// "clear" (.some(nil)). Changing the project or category without setting
/// `billable` re-derives it.
public struct TimeEntryChanges: Sendable {
    public var start: Date?
    public var end: Date??
    public var projectID: Int64??
    public var categoryID: Int64??
    public var title: String??
    public var notes: String??
    public var tags: [String]?
    public var billable: Bool?
    public var status: EntryStatus?
    public init() {}
}
