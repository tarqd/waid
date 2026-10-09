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

/// Something the computer observed: a window in front, an agent session.
/// Activities are evidence; they are categorized but not edited.
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
    public var note: String?
    public var meta: String?
    /// Kept out of queries and reports (e.g. private browsing).
    public var hidden: Bool = false

    /// Filled in by queries: the project from assignment or rules.
    public var projectID: Int64?
    public var project: String?

    public func duration(now: Date = Date()) -> TimeInterval {
        (end ?? now).timeIntervalSince(start)
    }
}

public struct Project: Codable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var parentID: Int64?
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
    public var projectID: Int64
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
    public var title: String?
    public var notes: String?
    public var tags: [String]
    public var billable: Bool
    public var origin: EntryOrigin
    /// "user", or "agent:<client>" for entries written over MCP.
    public var author: String
    public var status: EntryStatus

    /// Filled in by queries: the project's display path ("Clients / Acme").
    public var project: String?

    public func duration(now: Date = Date()) -> TimeInterval {
        (end ?? max(now, start)).timeIntervalSince(start)
    }
}

public struct NewTimeEntry: Sendable {
    public var start: Date
    public var end: Date?
    public var projectID: Int64?
    public var title: String?
    public var notes: String?
    public var tags: [String] = []
    public var billable = false
    public var origin: EntryOrigin
    public var author = "user"
    public var status = EntryStatus.confirmed

    public init(start: Date, end: Date?, projectID: Int64? = nil, title: String? = nil, origin: EntryOrigin) {
        self.start = start
        self.end = end
        self.projectID = projectID
        self.title = title
        self.origin = origin
    }
}

/// Partial update. Double optionals distinguish "leave alone" (nil) from
/// "clear" (.some(nil)).
public struct TimeEntryChanges: Sendable {
    public var start: Date?
    public var end: Date??
    public var projectID: Int64??
    public var title: String??
    public var notes: String??
    public var tags: [String]?
    public var billable: Bool?
    public var status: EntryStatus?
    public init() {}
}
