import Foundation
import WaidCore

/// The waid MCP tool surface: read activity, summarize it, categorize it, and
/// let agents record their own work and drive timers.
public enum WaidTools {
    public static let instructions = """
        waid is a local, private time tracker. It records which app/window/URL is frontmost \
        (source "window"), manual timers and entries ("timer", "manual"), and work done by \
        coding agents ("agent:<name>", e.g. "agent:claude-code").
        Sources overlap in wall-clock time (an agent can work while the user browses), so \
        summaries report seconds per source; don't add them together without saying so.
        Projects come from explicit assignment or, failing that, from rules evaluated at query \
        time, so a new rule recategorizes history immediately. To categorize, prefer \
        top_uncategorized -> create_rule over assigning spans one by one.
        Times are ISO 8601; bare dates and datetimes without an offset are the user's local time.
        """

    public static func make(store: Store, now: @escaping () -> Date = Date.init) -> [Tool] {
        let rangeProps: [String: JSONValue] = [
            "range": ["type": "string", "enum": .array(TimeRange.names.map { .string($0) }),
                      "description": "Named range. Takes precedence over start/end. Defaults to today."],
            "start": ["type": "string", "description": "ISO 8601 date or datetime (inclusive)."],
            "end": ["type": "string", "description": "ISO 8601 date (inclusive of that day) or datetime (exclusive)."],
        ]
        func range(_ a: Arguments) throws -> DateInterval {
            do {
                return try TimeRange.resolve(range: a.string("range"), start: a.string("start"), end: a.string("end"), now: now())
            } catch let e as TimeRange.ParseError { throw ToolError(e.description) }
        }
        func filter(_ a: Arguments) throws -> Store.ActivityFilter {
            var f = Store.ActivityFilter()
            f.sources = try a.strings("sources")
            if let name = try a.string("project") { f.projectID = try store.requireProject(named: name).id }
            f.uncategorizedOnly = try a.bool("uncategorized_only") ?? false
            f.text = try a.string("text")
            return f
        }
        let filterProps: [String: JSONValue] = [
            "project": ["type": "string", "description": "Only spans in this project."],
            "sources": ["type": "array", "items": ["type": "string"],
                        "description": "Only these sources, e.g. [\"window\"] or [\"agent:claude-code\"]."],
            "text": ["type": "string", "description": "Substring match on title, app, URL, path or note."],
        ]
        func schema(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
            ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) }),
             "additionalProperties": false]
        }

        return [
            Tool(
                name: "get_status",
                description: "What the user is doing right now: current frontmost activity, running timer, and when agent sessions were last imported.",
                inputSchema: schema([:]), readOnly: true
            ) { _ in
                let current = try store.latestActivity(source: Source.window)
                    .flatMap { now().timeIntervalSince($0.end ?? now()) < 60 ? $0 : nil }
                return Status(
                    now: now(),
                    current: current.map { ActivityView($0, now: now()) },
                    runningTimer: try store.runningTimer().map { ActivityView($0, now: now()) },
                    lastAgentImport: try store.value(forKey: "ingest.claude-code.last_run")
                        .flatMap(Double.init).map(Date.init(timeIntervalSince1970:)))
            },

            Tool(
                name: "query_activity",
                description: "List tracked time spans in a range, oldest first, with their resolved project.",
                inputSchema: schema(rangeProps.merging(filterProps) { $1 }.merging([
                    "uncategorized_only": ["type": "boolean", "description": "Only spans with no project."],
                    "limit": ["type": "integer", "description": "Max spans to return (default 200)."],
                ]) { $1 }),
                readOnly: true
            ) { a in
                var f = try filter(a)
                f.limit = try a.int("limit") ?? 200
                return try store.activities(in: try range(a), filter: f, now: now()).map { ActivityView($0, now: now()) }
            },

            Tool(
                name: "summarize",
                description: "Total time in a range grouped by project, app, source or day. Returns minutes per source for each group.",
                inputSchema: schema(rangeProps.merging(filterProps) { $1 }.merging([
                    "group_by": ["type": "string", "enum": .array(Store.GroupBy.allCases.map { .string($0.rawValue) }),
                                 "description": "Default: project."],
                ]) { $1 }),
                readOnly: true
            ) { a in
                let groupName = try a.string("group_by") ?? "project"
                guard let groupBy = Store.GroupBy(rawValue: groupName) else { throw ToolError("unknown group_by \"\(groupName)\"") }
                let interval = try range(a)
                let rows = try store.summary(in: interval, groupBy: groupBy, filter: try filter(a), now: now())
                return Summary(
                    start: interval.start, end: interval.end, groupBy: groupBy.rawValue,
                    groups: rows.map { SummaryGroup(key: $0.key, minutesBySource: $0.secondsBySource.mapValues(minutes)) })
            },

            Tool(
                name: "top_uncategorized",
                description: "The biggest chunks of uncategorized time in a range, grouped by app, website host, or agent working directory, with example titles. Use this to propose rules.",
                inputSchema: schema(rangeProps.merging([
                    "limit": ["type": "integer", "description": "Max groups (default 25)."],
                ]) { $1 }),
                readOnly: true
            ) { a in
                var f = Store.ActivityFilter()
                f.uncategorizedOnly = true
                var groups: [String: UncategorizedGroup] = [:]
                for activity in try store.activities(in: try range(a), filter: f, now: now()) {
                    let (field, value): (String, String)
                    if let host = activity.url.flatMap({ URL(string: $0)?.host }) {
                        (field, value) = ("url", host)
                    } else if activity.source.hasPrefix(Source.agentPrefix), let path = activity.path {
                        (field, value) = ("path", path)
                    } else {
                        (field, value) = (activity.bundleID != nil ? "bundle_id" : "source",
                                          activity.bundleID ?? activity.source)
                    }
                    let key = "\(activity.source)|\(field)|\(value)"
                    var group = groups[key] ?? UncategorizedGroup(
                        source: activity.source, field: field, value: value, app: activity.appName, minutes: 0, examples: [])
                    group.minutes += minutes(activity.duration(now: now()))
                    if let title = activity.title, group.examples.count < 5, !group.examples.contains(title) {
                        group.examples.append(title)
                    }
                    groups[key] = group
                }
                return groups.values.sorted { $0.minutes > $1.minutes }.prefix(try a.int("limit") ?? 25)
                    .map { var g = $0; g.minutes = (g.minutes * 10).rounded() / 10; return g }
            },

            Tool(
                name: "list_projects",
                description: "All projects with their categorization rules.",
                inputSchema: schema(["include_archived": ["type": "boolean"]]), readOnly: true
            ) { a in
                let rules = try store.rules()
                return try store.projects(includeArchived: try a.bool("include_archived") ?? false).map { p in
                    ProjectView(id: p.id, name: p.name, color: p.color, archived: p.archived,
                                rules: rules.filter { $0.projectID == p.id }.map { RuleView($0, project: p.name) })
                }
            },

            Tool(
                name: "create_project",
                description: "Create a project (no-op if it exists).",
                inputSchema: schema(["name": ["type": "string"], "color": ["type": "string", "description": "Hex color, e.g. #3b82f6."]],
                                    required: ["name"])
            ) { a in
                try store.ensureProject(named: try a.requiredString("name"), color: try a.string("color"))
            },

            Tool(
                name: "create_rule",
                description: "Categorize matching time into a project, retroactively and going forward. Matching is case-insensitive. Returns how many spans in the last 30 days the rule now claims.",
                inputSchema: schema([
                    "project": ["type": "string"],
                    "field": ["type": "string", "enum": .array(RuleField.allCases.map { .string($0.rawValue) }),
                              "description": "bundle_id (e.g. com.apple.Safari), app_name, title, url, path (document path or agent working dir), source."],
                    "op": ["type": "string", "enum": .array(RuleOp.allCases.map { .string($0.rawValue) })],
                    "pattern": ["type": "string"],
                    "priority": ["type": "integer", "description": "Higher wins when rules conflict. Default 0."],
                    "create_project": ["type": "boolean", "description": "Create the project if missing (default true)."],
                ], required: ["project", "field", "op", "pattern"])
            ) { a in
                let name = try a.requiredString("project")
                let project = try (a.bool("create_project") ?? true)
                    ? store.ensureProject(named: name) : store.requireProject(named: name)
                let fieldName = try a.requiredString("field"), opName = try a.requiredString("op")
                guard let field = RuleField(rawValue: fieldName) else { throw ToolError("unknown field \"\(fieldName)\"") }
                guard let op = RuleOp(rawValue: opName) else { throw ToolError("unknown op \"\(opName)\"") }
                let rule = try store.addRule(projectID: project.id, field: field, op: op,
                                             pattern: try a.requiredString("pattern"), priority: try a.int("priority") ?? 0)
                let recent = try store.activities(in: TimeRange.named("last_30_days", now: now())!, now: now())
                let engine = RuleEngine(rules: try store.rules())
                let claimed = recent.filter { $0.assignedProjectID == nil && engine.firstMatch(for: $0)?.id == rule.id }
                return CreatedRule(rule: RuleView(rule, project: project.name), matchedLast30Days: claimed.count,
                                   minutesLast30Days: minutes(claimed.reduce(0) { $0 + $1.duration(now: now()) }))
            },

            Tool(
                name: "delete_rule",
                description: "Delete a categorization rule by id.",
                inputSchema: schema(["id": ["type": "integer"]], required: ["id"]), destructive: true
            ) { a in
                guard let id = try a.int("id") else { throw ToolError("missing required argument \"id\"") }
                try store.deleteRule(id: Int64(id))
                return "deleted rule \(id)"
            },

            Tool(
                name: "assign_activity",
                description: "Explicitly set the project for specific spans (overrides rules). Pass project null to clear.",
                inputSchema: schema([
                    "ids": ["type": "array", "items": ["type": "integer"]],
                    "project": ["type": ["string", "null"]],
                ], required: ["ids"])
            ) { a in
                let ids = try a.ints("ids") ?? []
                let projectID = try a.string("project").map { try store.ensureProject(named: $0).id }
                return ["updated": try store.assign(activityIDs: ids, projectID: projectID)]
            },

            Tool(
                name: "start_timer",
                description: "Start a timer for a project, stopping any running timer.",
                inputSchema: schema(["project": ["type": "string"], "note": ["type": "string"]], required: ["project"])
            ) { a in
                let project = try store.ensureProject(named: try a.requiredString("project"))
                if let running = try store.runningTimer() { try store.setEnd(activityID: running.id, end: now()) }
                let id = try store.insertActivity(start: now(), end: nil, source: Source.timer,
                                                  projectID: project.id, note: try a.string("note"))
                return ActivityView(try store.activity(id: id)!, now: now(), project: project.name)
            },

            Tool(
                name: "stop_timer",
                description: "Stop the running timer, if any.",
                inputSchema: schema([:])
            ) { _ in
                guard let running = try store.runningTimer() else { return "no timer running" }
                try store.setEnd(activityID: running.id, end: now())
                return ActivityView(try store.activity(id: running.id)!, now: now())
            },

            Tool(
                name: "add_time_entry",
                description: "Add a manual time entry (e.g. a meeting away from the computer).",
                inputSchema: schema([
                    "start": ["type": "string"], "end": ["type": "string"],
                    "project": ["type": "string"], "note": ["type": "string"],
                ], required: ["start", "end", "project"])
            ) { a in
                let interval = try range(Arguments(["start": .string(try a.requiredString("start")),
                                                    "end": .string(try a.requiredString("end"))]))
                let project = try store.ensureProject(named: try a.requiredString("project"))
                let id = try store.insertActivity(start: interval.start, end: interval.end, source: Source.manual,
                                                  projectID: project.id, note: try a.string("note"))
                return ActivityView(try store.activity(id: id)!, now: now(), project: project.name)
            },

            Tool(
                name: "record_agent_work",
                description: "Record a span of work done by an AI agent, so it shows up next to the user's own time. Re-sending the same external_id updates the span instead of duplicating it.",
                inputSchema: schema([
                    "agent": ["type": "string", "description": "Agent name, e.g. \"codex\"; stored as source agent:<name>."],
                    "start": ["type": "string"],
                    "end": ["type": "string", "description": "Defaults to now."],
                    "title": ["type": "string", "description": "What the work was."],
                    "path": ["type": "string", "description": "Working directory or repo, used by path rules."],
                    "external_id": ["type": "string", "description": "Stable id for idempotent updates, e.g. a session id."],
                    "project": ["type": "string", "description": "Optional explicit project."],
                ], required: ["agent", "start", "title"])
            ) { a in
                let agent = try a.requiredString("agent")
                guard agent.range(of: "^[a-z0-9._-]+$", options: [.regularExpression, .caseInsensitive]) != nil else {
                    throw ToolError("agent must be a short identifier like \"codex\"")
                }
                let startString = try a.requiredString("start")
                guard let start = TimeRange.parseDate(startString) else { throw ToolError("can't parse start \"\(startString)\"") }
                let end = try a.string("end").map { s in try TimeRange.parseDate(s) ?? { throw ToolError("can't parse end \"\(s)\"") }() } ?? now()
                guard end >= start else { throw ToolError("end is before start") }
                let source = Source.agent(agent.lowercased())
                let externalID = try a.string("external_id") ?? UUID().uuidString
                try store.upsertExternal(source: source, externalID: externalID, start: start, end: end,
                                         title: try a.requiredString("title"), path: try a.string("path"))
                let row = try store.db.query("SELECT id FROM activities WHERE source = ? AND external_id = ?", [source, externalID])
                let id = row.first!.int("id")!
                if let name = try a.string("project") {
                    try store.assign(activityIDs: [id], projectID: try store.ensureProject(named: name).id)
                }
                return ActivityView(try store.activity(id: id)!, now: now())
            },

            Tool(
                name: "import_agent_sessions",
                description: "Import Claude Code sessions from local transcripts (~/.claude/projects). The daemon does this periodically; call it to refresh now.",
                inputSchema: schema(["full": ["type": "boolean", "description": "Rescan all transcripts, not just changed ones."]])
            ) { a in
                try ClaudeCodeIngestor().ingest(into: store, full: try a.bool("full") ?? false)
            },
        ]
    }

    static func minutes(_ seconds: TimeInterval) -> Double { (seconds / 6).rounded() / 10 }
}

// MARK: Output shapes

struct ActivityView: Encodable {
    var id: Int64
    var start: Date
    var end: Date?
    var minutes: Double
    var source: String
    var app: String?
    var bundleID: String?
    var title: String?
    var url: String?
    var path: String?
    var project: String?
    var projectFrom: String?
    var note: String?

    init(_ a: Activity, now: Date, project: String? = nil) {
        id = a.id; start = a.start; end = a.end; minutes = WaidTools.minutes(a.duration(now: now))
        source = a.source; app = a.appName; bundleID = a.bundleID; title = a.title; url = a.url; path = a.path
        self.project = project ?? a.project
        projectFrom = a.assignedProjectID != nil ? "assigned" : (a.projectID != nil ? "rule" : nil)
        note = a.note
    }

    enum CodingKeys: String, CodingKey {
        case id, start, end, minutes, source, app, title, url, path, project, note
        case bundleID = "bundle_id", projectFrom = "project_from"
    }
}

struct Status: Encodable {
    var now: Date
    var current: ActivityView?
    var runningTimer: ActivityView?
    var lastAgentImport: Date?
    enum CodingKeys: String, CodingKey {
        case now, current, runningTimer = "running_timer", lastAgentImport = "last_agent_import"
    }
}

struct SummaryGroup: Encodable {
    var key: String
    var minutesBySource: [String: Double]
    enum CodingKeys: String, CodingKey { case key, minutesBySource = "minutes_by_source" }
}

struct Summary: Encodable {
    var start: Date
    var end: Date
    var groupBy: String
    var groups: [SummaryGroup]
    enum CodingKeys: String, CodingKey { case start, end, groups, groupBy = "group_by" }
}

struct UncategorizedGroup: Encodable {
    var source: String
    var field: String
    var value: String
    var app: String?
    var minutes: Double
    var examples: [String]
}

struct RuleView: Encodable {
    var id: Int64
    var project: String
    var field: String
    var op: String
    var pattern: String
    var priority: Int
    init(_ r: Rule, project: String) {
        id = r.id; self.project = project; field = r.field.rawValue; op = r.op.rawValue
        pattern = r.pattern; priority = r.priority
    }
}

struct ProjectView: Encodable {
    var id: Int64
    var name: String
    var color: String?
    var archived: Bool
    var rules: [RuleView]
}

struct CreatedRule: Encodable {
    var rule: RuleView
    var matchedLast30Days: Int
    var minutesLast30Days: Double
    enum CodingKeys: String, CodingKey {
        case rule, matchedLast30Days = "matched_last_30_days", minutesLast30Days = "minutes_last_30_days"
    }
}
