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

/// Where a span of time came from. Sources overlap by design: an agent can be
/// working in a repo while the user is in a browser.
public enum Source {
    public static let window = "window"
    public static let timer = "timer"
    public static let manual = "manual"
    public static let agentPrefix = "agent:"

    public static func agent(_ name: String) -> String { agentPrefix + name }
}

public struct Activity: Codable, Equatable, Sendable {
    public var id: Int64
    public var start: Date
    /// nil while still running (only for timers).
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
