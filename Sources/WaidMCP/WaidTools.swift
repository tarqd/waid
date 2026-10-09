import Foundation
import WaidCore

/// The waid MCP tool surface: read what happened (activities), manage what the
/// user claims (time entries), and categorize in between.
public enum WaidTools {
    public static let instructions = """
        waid is a local, private time tracker with two kinds of data:
        - Activities: what the computer observed. Frontmost app/window/URL (source "window") and \
        coding-agent sessions ("agent:<name>"). Automatic and fine-grained; categorized into \
        projects by rules, never edited. Sources overlap (an agent can work while the user \
        browses), so activity summaries report minutes per source.
        - Time entries: what the user claims they did; the numbers for reports and billing. \
        Entries never overlap. Drafts are suggestions that don't count until confirmed.
        Typical flows: "where did my time go" -> summarize kind=activities. "Log my week" -> \
        suggest_time_entries, review/edit titles with update_time_entry, then confirm_time_entries \
        once the user agrees. "What haven't I logged" -> summarize kind=unlogged.
        Rules apply retroactively; to categorize, prefer top_uncategorized -> create_rule over \
        assigning activities one by one. Entries you create are attributed to you as the author.
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
        func date(_ a: Arguments, _ key: String) throws -> Date? {
            guard let s = try a.string(key) else { return nil }
            guard let d = TimeRange.parseDate(s) else { throw ToolError("can't parse \(key) \"\(s)\" as an ISO 8601 date/datetime") }
            return d
        }
        func activityFilter(_ a: Arguments) throws -> Store.ActivityFilter {
            var f = Store.ActivityFilter()
            f.sources = try a.strings("sources")
            if let name = try a.string("project") { f.projectID = try store.requireProject(named: name).id }
            f.uncategorizedOnly = try a.bool("uncategorized_only") ?? false
            f.text = try a.string("text")
            return f
        }
        func suggester(_ a: Arguments) throws -> EntrySuggester {
            var s = EntrySuggester()
            if let m = try a.int("merge_gap_minutes") { s.mergeGap = TimeInterval(max(0, m) * 60) }
            if let m = try a.int("min_minutes") { s.minDuration = TimeInterval(max(1, m) * 60) }
            s.includeAgents = try a.bool("include_agents") ?? false
            return s
        }
        let activityFilterProps: [String: JSONValue] = [
            "project": ["type": "string", "description": "Only this project."],
            "sources": ["type": "array", "items": ["type": "string"],
                        "description": "Only these sources, e.g. [\"window\"] or [\"agent:claude-code\"]."],
            "text": ["type": "string", "description": "Substring match on title, app, URL, path or note."],
        ]
        let suggestProps: [String: JSONValue] = [
            "merge_gap_minutes": ["type": "integer", "description": "Merge same-project blocks this close, absorbing interruptions (default 5)."],
            "min_minutes": ["type": "integer", "description": "Shortest block worth an entry (default 10)."],
            "include_agents": ["type": "boolean", "description": "Count agent sessions as the user's time (default false)."],
        ]
        let entryFields: [String: JSONValue] = [
            "project": ["type": ["string", "null"], "description": "Project name; created if missing. null for none."],
            "title": ["type": ["string", "null"]],
            "notes": ["type": ["string", "null"]],
            "tags": ["type": "array", "items": ["type": "string"]],
            "billable": ["type": "boolean"],
        ]
        func schema(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
            ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) }),
             "additionalProperties": false]
        }
        func projectID(_ a: Arguments) throws -> Int64?? {
            guard a.has("project") else { return nil }
            return .some(try a.string("project").map { try store.ensureProject(named: $0).id })
        }
        func nullableString(_ a: Arguments, _ key: String) throws -> String?? {
            a.has(key) ? .some(try a.string(key)) : nil
        }
        func requiredID(_ a: Arguments) throws -> Int64 {
            guard let id = try a.int("id") else { throw ToolError("missing required argument \"id\"") }
            return Int64(id)
        }

        return [
            // MARK: Status

            Tool(
                name: "get_status",
                description: "What the user is doing right now: current frontmost activity, running timer, today's unlogged minutes, and when agent sessions were last imported.",
                inputSchema: schema([:]), readOnly: true
            ) { _, _ in
                let current = try store.latestActivity(source: Source.window)
                    .flatMap { now().timeIntervalSince($0.end ?? now()) < 60 ? $0 : nil }
                let unlogged = try store.unloggedSummary(in: TimeRange.named("today", now: now())!, groupBy: .project, now: now())
                return Status(
                    now: now(),
                    current: current.map { ActivityView($0, now: now()) },
                    runningTimer: try store.runningEntry().map { EntryView($0, now: now()) },
                    unloggedTodayMinutes: minutes(unlogged.reduce(0) { $0 + $1.seconds }),
                    lastAgentImport: try store.value(forKey: "ingest.claude-code.last_run")
                        .flatMap(Double.init).map(Date.init(timeIntervalSince1970:)))
            },

            // MARK: Activities

            Tool(
                name: "query_activity",
                description: "List observed activities in a range, oldest first, with their resolved project.",
                inputSchema: schema(rangeProps.merging(activityFilterProps) { $1 }.merging([
                    "uncategorized_only": ["type": "boolean", "description": "Only activities with no project."],
                    "limit": ["type": "integer", "description": "Max activities to return (default 200)."],
                ]) { $1 }),
                readOnly: true
            ) { a, _ in
                var f = try activityFilter(a)
                f.limit = try a.int("limit") ?? 200
                return try store.activities(in: try range(a), filter: f, now: now()).map { ActivityView($0, now: now()) }
            },

            Tool(
                name: "summarize",
                description: """
                    Total time in a range. kind=activities (default): observed time grouped by project, app, source \
                    or day, in minutes per source. kind=entries: confirmed time entries by project or day, with \
                    billable minutes. kind=unlogged: categorized activity time not covered by any confirmed entry, \
                    by project or day.
                    """,
                inputSchema: schema(rangeProps.merging(activityFilterProps) { $1 }.merging([
                    "kind": ["type": "string", "enum": ["activities", "entries", "unlogged"]],
                    "group_by": ["type": "string", "enum": .array(Store.GroupBy.allCases.map { .string($0.rawValue) }),
                                 "description": "Default: project. Entries and unlogged support project and day only."],
                    "include_drafts": ["type": "boolean", "description": "kind=entries: count drafts too (default false)."],
                ]) { $1 }),
                readOnly: true
            ) { a, _ in
                let groupName = try a.string("group_by") ?? "project"
                guard let groupBy = Store.GroupBy(rawValue: groupName) else { throw ToolError("unknown group_by \"\(groupName)\"") }
                let interval = try range(a)
                let kind = try a.string("kind") ?? "activities"
                func entryGroups(_ rows: [Store.EntrySummaryRow]) -> [SummaryGroup] {
                    rows.map { SummaryGroup(key: $0.key, minutes: minutes($0.seconds),
                                            billableMinutes: kind == "entries" ? minutes($0.billableSeconds) : nil) }
                }
                let groups: [SummaryGroup]
                switch kind {
                case "activities":
                    groups = try store.summary(in: interval, groupBy: groupBy, filter: try activityFilter(a), now: now())
                        .map { SummaryGroup(key: $0.key, minutesBySource: $0.secondsBySource.mapValues(minutes)) }
                case "entries":
                    let project = try a.string("project").map { try store.requireProject(named: $0).id }
                    groups = entryGroups(try store.entrySummary(in: interval, groupBy: groupBy,
                                                                includeDrafts: try a.bool("include_drafts") ?? false,
                                                                projectID: project, now: now()))
                case "unlogged":
                    groups = entryGroups(try store.unloggedSummary(in: interval, groupBy: groupBy, now: now()))
                default:
                    throw ToolError("unknown kind \"\(kind)\"; use activities, entries or unlogged")
                }
                return Summary(start: interval.start, end: interval.end, kind: kind, groupBy: groupBy.rawValue, groups: groups)
            },

            Tool(
                name: "top_uncategorized",
                description: "The biggest chunks of uncategorized activity in a range, grouped by app, website host, or agent working directory, with example titles. Use this to propose rules.",
                inputSchema: schema(rangeProps.merging([
                    "limit": ["type": "integer", "description": "Max groups (default 25)."],
                ]) { $1 }),
                readOnly: true
            ) { a, _ in
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
                    group.minutes += activity.duration(now: now()) / 60
                    if let title = activity.title, group.examples.count < 5, !group.examples.contains(title) {
                        group.examples.append(title)
                    }
                    groups[key] = group
                }
                return groups.values.sorted { $0.minutes > $1.minutes }.prefix(try a.int("limit") ?? 25)
                    .map { var g = $0; g.minutes = (g.minutes * 10).rounded() / 10; return g }
            },

            Tool(
                name: "assign_activity",
                description: "Explicitly set the project for specific activities (overrides rules). Pass project null to clear.",
                inputSchema: schema([
                    "ids": ["type": "array", "items": ["type": "integer"]],
                    "project": ["type": ["string", "null"]],
                ], required: ["ids"])
            ) { a, _ in
                let ids = try a.ints("ids") ?? []
                let projectID = try a.string("project").map { try store.ensureProject(named: $0).id }
                return ["updated": try store.assign(activityIDs: ids, projectID: projectID)]
            },

            Tool(
                name: "hide_activity",
                description: "Hide activities from all queries and reports (e.g. something private), or unhide them.",
                inputSchema: schema([
                    "ids": ["type": "array", "items": ["type": "integer"]],
                    "hidden": ["type": "boolean", "description": "Default true; false unhides."],
                ], required: ["ids"])
            ) { a, _ in
                ["updated": try store.setHidden(activityIDs: try a.ints("ids") ?? [], hidden: try a.bool("hidden") ?? true)]
            },

            // MARK: Projects and rules

            Tool(
                name: "list_projects",
                description: "All projects with their parent and categorization rules.",
                inputSchema: schema(["include_archived": ["type": "boolean"]]), readOnly: true
            ) { a, _ in
                let rules = try store.rules()
                let paths = try store.projectPaths()
                return try store.projects(includeArchived: try a.bool("include_archived") ?? false).map { p in
                    ProjectView(id: p.id, name: p.name, path: paths[p.id] ?? p.name, color: p.color, archived: p.archived,
                                rules: rules.filter { $0.projectID == p.id }.map { RuleView($0, project: p.name) })
                }
            },

            Tool(
                name: "create_project",
                description: "Create a project, optionally nested under a parent (no-op if it exists).",
                inputSchema: schema([
                    "name": ["type": "string"],
                    "parent": ["type": "string", "description": "Parent project name; created if missing."],
                    "color": ["type": "string", "description": "Hex color, e.g. #3b82f6."],
                ], required: ["name"])
            ) { a, _ in
                let parent = try a.string("parent").map { try store.ensureProject(named: $0).id }
                let project = try store.ensureProject(named: try a.requiredString("name"), color: try a.string("color"), parentID: parent)
                return ProjectView(id: project.id, name: project.name, path: try store.projectPaths()[project.id] ?? project.name,
                                   color: project.color, archived: project.archived, rules: [])
            },

            Tool(
                name: "create_rule",
                description: "Categorize matching activities into a project, retroactively and going forward. Matching is case-insensitive. Returns how many activities in the last 30 days the rule now claims.",
                inputSchema: schema([
                    "project": ["type": "string"],
                    "field": ["type": "string", "enum": .array(RuleField.allCases.map { .string($0.rawValue) }),
                              "description": "bundle_id (e.g. com.apple.Safari), app_name, title, url, path (document path or agent working dir), source."],
                    "op": ["type": "string", "enum": .array(RuleOp.allCases.map { .string($0.rawValue) })],
                    "pattern": ["type": "string"],
                    "priority": ["type": "integer", "description": "Higher wins when rules conflict. Default 0."],
                    "create_project": ["type": "boolean", "description": "Create the project if missing (default true)."],
                ], required: ["project", "field", "op", "pattern"])
            ) { a, _ in
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
            ) { a, _ in
                let id = try requiredID(a)
                try store.deleteRule(id: id)
                return "deleted rule \(id)"
            },

            // MARK: Time entries

            Tool(
                name: "query_time_entries",
                description: "List time entries in a range, oldest first.",
                inputSchema: schema(rangeProps.merging([
                    "project": ["type": "string"],
                    "status": ["type": "string", "enum": ["draft", "confirmed"], "description": "Default: both."],
                    "text": ["type": "string", "description": "Substring match on title, notes or tags."],
                ]) { $1 }),
                readOnly: true
            ) { a, _ in
                var f = Store.EntryFilter()
                if let s = try a.string("status") {
                    guard let status = EntryStatus(rawValue: s) else { throw ToolError("unknown status \"\(s)\"") }
                    f.status = status
                }
                if let name = try a.string("project") { f.projectID = try store.requireProject(named: name).id }
                f.text = try a.string("text")
                return try store.timeEntries(in: try range(a), filter: f, now: now()).map { EntryView($0, now: now()) }
            },

            Tool(
                name: "create_time_entry",
                description: "Create a time entry. Fails if it would overlap another entry; adjust or delete that one first.",
                inputSchema: schema(entryFields.merging([
                    "start": ["type": "string"],
                    "end": ["type": "string"],
                    "status": ["type": "string", "enum": ["draft", "confirmed"],
                               "description": "Default confirmed. Use draft when proposing time the user hasn't approved."],
                    "from_activities": ["type": "boolean", "description": "Set when the entry is based on observed activities rather than the user's say-so."],
                ]) { $1 }, required: ["start", "end"])
            ) { a, ctx in
                guard let start = try date(a, "start"), let end = try date(a, "end") else {
                    throw ToolError("start and end are required")
                }
                var new = NewTimeEntry(start: start, end: end, origin: (try a.bool("from_activities") ?? false) ? .fromActivities : .manual)
                new.projectID = try projectID(a) ?? nil
                new.title = try a.string("title")
                new.notes = try a.string("notes")
                new.tags = try a.strings("tags") ?? []
                new.billable = try a.bool("billable") ?? false
                new.author = ctx.author
                if let s = try a.string("status") {
                    guard let status = EntryStatus(rawValue: s) else { throw ToolError("unknown status \"\(s)\"") }
                    new.status = status
                }
                return EntryView(try store.createEntry(new, now: now()), now: now())
            },

            Tool(
                name: "update_time_entry",
                description: "Change fields of a time entry. Omitted fields are left alone; null clears project/title/notes.",
                inputSchema: schema(entryFields.merging([
                    "id": ["type": "integer"],
                    "start": ["type": "string"],
                    "end": ["type": "string"],
                    "status": ["type": "string", "enum": ["draft", "confirmed"]],
                ]) { $1 }, required: ["id"])
            ) { a, _ in
                var changes = TimeEntryChanges()
                changes.start = try date(a, "start")
                if let end = try date(a, "end") { changes.end = .some(end) }
                changes.projectID = try projectID(a)
                changes.title = try nullableString(a, "title")
                changes.notes = try nullableString(a, "notes")
                changes.tags = try a.strings("tags")
                changes.billable = try a.bool("billable")
                if let s = try a.string("status") {
                    guard let status = EntryStatus(rawValue: s) else { throw ToolError("unknown status \"\(s)\"") }
                    changes.status = status
                }
                return EntryView(try store.updateEntry(id: try requiredID(a), changes, now: now()), now: now())
            },

            Tool(
                name: "delete_time_entry",
                description: "Delete a time entry by id.",
                inputSchema: schema(["id": ["type": "integer"]], required: ["id"]), destructive: true
            ) { a, _ in
                let id = try requiredID(a)
                try store.deleteEntry(id: id)
                return "deleted time entry \(id)"
            },

            Tool(
                name: "suggest_time_entries",
                description: """
                    Draft time entries from categorized activities in a range: contiguous work on one project becomes \
                    one draft, short interruptions are absorbed, and time already covered by entries is skipped. \
                    Re-running replaces earlier suggestions in the range. Returns drafts with the evidence behind \
                    each; improve titles with update_time_entry, then confirm_time_entries when the user agrees. \
                    Uncategorized activity is ignored, so categorize first (top_uncategorized -> create_rule).
                    """,
                inputSchema: schema(rangeProps.merging(suggestProps) { $1 })
            ) { a, ctx in
                try store.suggestEntries(in: try range(a), using: try suggester(a), author: ctx.author, now: now()).map {
                    SuggestionView(entry: EntryView($0.entry, now: now()),
                                   evidence: $0.evidence.map { EvidenceView(label: $0.label, minutes: minutes($0.seconds)) })
                }
            },

            Tool(
                name: "confirm_time_entries",
                description: "Confirm draft time entries so they count in reports.",
                inputSchema: schema(["ids": ["type": "array", "items": ["type": "integer"]]], required: ["ids"])
            ) { a, _ in
                ["confirmed": try store.setStatus(entryIDs: try a.ints("ids") ?? [], .confirmed, now: now())]
            },

            Tool(
                name: "start_timer",
                description: "Start a running time entry, stopping any running one.",
                inputSchema: schema([
                    "project": ["type": "string"], "title": ["type": "string"], "notes": ["type": "string"],
                ])
            ) { a, ctx in
                let project = try a.string("project").map { try store.ensureProject(named: $0).id }
                let result = try store.startTimer(projectID: project, title: try a.string("title"),
                                                  notes: try a.string("notes"), author: ctx.author, now: now())
                return TimerChange(started: EntryView(result.started, now: now()),
                                   stopped: result.stopped.map { EntryView($0, now: now()) })
            },

            Tool(
                name: "stop_timer",
                description: "Stop the running time entry, if any.",
                inputSchema: schema([:])
            ) { _, _ in
                guard let stopped = try store.stopTimer(now: now()) else { return "no timer running" }
                return EntryView(stopped, now: now())
            },

            // MARK: Agents

            Tool(
                name: "record_agent_work",
                description: "Record a span of work done by an AI agent as an activity, so it shows up next to the user's own time. Re-sending the same external_id updates the span instead of duplicating it. This is evidence, not a time entry.",
                inputSchema: schema([
                    "agent": ["type": "string", "description": "Agent name, e.g. \"codex\"; stored as source agent:<name>."],
                    "start": ["type": "string"],
                    "end": ["type": "string", "description": "Defaults to now."],
                    "title": ["type": "string", "description": "What the work was."],
                    "path": ["type": "string", "description": "Working directory or repo, used by path rules."],
                    "external_id": ["type": "string", "description": "Stable id for idempotent updates, e.g. a session id."],
                    "project": ["type": "string", "description": "Optional explicit project."],
                ], required: ["agent", "start", "title"])
            ) { a, _ in
                let agent = try a.requiredString("agent")
                guard agent.range(of: "^[a-z0-9._-]+$", options: [.regularExpression, .caseInsensitive]) != nil else {
                    throw ToolError("agent must be a short identifier like \"codex\"")
                }
                guard let start = try date(a, "start") else { throw ToolError("missing required argument \"start\"") }
                let end = try date(a, "end") ?? now()
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
                description: "Import Claude Code sessions from local transcripts (~/.claude/projects) as activities. The daemon does this periodically; call it to refresh now.",
                inputSchema: schema(["full": ["type": "boolean", "description": "Rescan all transcripts, not just changed ones."]])
            ) { a, _ in
                try ClaudeCodeIngestor().ingest(into: store, full: try a.bool("full") ?? false)
            },
        ]
    }

    static func minutes(_ seconds: TimeInterval) -> Double { (seconds / 6).rounded() / 10 }
}

extension Arguments {
    /// Whether the key was passed at all, including as null.
    func has(_ key: String) -> Bool { values[key] != nil }
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

    init(_ a: Activity, now: Date) {
        id = a.id; start = a.start; end = a.end; minutes = WaidTools.minutes(a.duration(now: now))
        source = a.source; app = a.appName; bundleID = a.bundleID; title = a.title; url = a.url; path = a.path
        project = a.project
        projectFrom = a.assignedProjectID != nil ? "assigned" : (a.projectID != nil ? "rule" : nil)
    }

    enum CodingKeys: String, CodingKey {
        case id, start, end, minutes, source, app, title, url, path, project
        case bundleID = "bundle_id", projectFrom = "project_from"
    }
}

struct EntryView: Encodable {
    var id: Int64
    var start: Date
    var end: Date?
    var minutes: Double
    var project: String?
    var title: String?
    var notes: String?
    var tags: [String]
    var billable: Bool
    var origin: String
    var author: String
    var status: String

    init(_ e: TimeEntry, now: Date) {
        id = e.id; start = e.start; end = e.end; minutes = WaidTools.minutes(e.duration(now: now))
        project = e.project; title = e.title; notes = e.notes; tags = e.tags; billable = e.billable
        origin = e.origin.rawValue; author = e.author; status = e.status.rawValue
    }
}

struct Status: Encodable {
    var now: Date
    var current: ActivityView?
    var runningTimer: EntryView?
    var unloggedTodayMinutes: Double
    var lastAgentImport: Date?
    enum CodingKeys: String, CodingKey {
        case now, current, runningTimer = "running_timer", unloggedTodayMinutes = "unlogged_today_minutes"
        case lastAgentImport = "last_agent_import"
    }
}

struct SummaryGroup: Encodable {
    var key: String
    var minutesBySource: [String: Double]?
    var minutes: Double?
    var billableMinutes: Double?

    init(key: String, minutesBySource: [String: Double]) {
        self.key = key
        self.minutesBySource = minutesBySource
    }

    init(key: String, minutes: Double, billableMinutes: Double?) {
        self.key = key
        self.minutes = minutes
        self.billableMinutes = billableMinutes
    }

    enum CodingKeys: String, CodingKey {
        case key, minutes, minutesBySource = "minutes_by_source", billableMinutes = "billable_minutes"
    }
}

struct Summary: Encodable {
    var start: Date
    var end: Date
    var kind: String
    var groupBy: String
    var groups: [SummaryGroup]
    enum CodingKeys: String, CodingKey { case start, end, kind, groups, groupBy = "group_by" }
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
    var path: String
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

struct EvidenceView: Encodable {
    var label: String
    var minutes: Double
}

struct SuggestionView: Encodable {
    var entry: EntryView
    var evidence: [EvidenceView]
}

struct TimerChange: Encodable {
    var started: EntryView
    var stopped: EntryView?
}
