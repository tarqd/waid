import Foundation
import WaidCore

/// The waid MCP tool surface: read what happened (activities), manage what the
/// user claims (time entries), and attribute both to clients, projects and
/// categories.
public enum WaidTools {
    public static let instructions = """
        waid is a local, private time tracker built for professional-services work.

        Attribution has two independent dimensions:
        - Project: what the work is for. A project with a client is an engagement (often with an \
        hours budget, status prospect/active/closed); one without is internal. Refer to projects as \
        "Client / Project" (e.g. "Acme / Phase 2") or by plain name when unambiguous.
        - Category: the kind of work (e.g. Presales, Implementation, Meetings, Admin). Categories can \
        be never-billable (presales), which overrides a billable project.
        Clients can have domains (acme.com) that attribute matching URLs to them.

        Two kinds of data:
        - Activities: what the computer observed. Frontmost app/window/URL (source "window") and \
        coding-agent sessions ("agent:<name>"). Attributed by rules evaluated at query time (a new rule \
        recategorizes history), never edited.
        - Time entries: what the user claims; the numbers for timesheets, budgets and billing. Never \
        overlap. Drafts don't count until confirmed. Billable is derived from project and category unless set.

        Claimed time vs evidence:
        - A Summary (summarize) is always about time entries: claimed time, with billable minutes and \
        utilization. Reports (timesheet, budget_status) are built from Summaries. Quote these when asked \
        how much time went to a client or project.
        - Evidence (evidence tool) is for claiming time, never presented as claimed time. kind=activities \
        totals observed activity per source; sources overlap, so they are never summed. kind=unlogged is \
        Unlogged time: work a suggestion would offer to claim, minus confirmed entries, with billable \
        minutes derived from the project and category as for time entries; claim billable work first.
        Breaking change: summarize used to default to activities and took a kind; it now reports time \
        entries only. Use the evidence tool for activities and unlogged time.

        Typical flows: "how much did I do for Acme" -> summarize. "Where did my time go" -> evidence. \
        "Log my week" -> suggest_time_entries, improve titles/notes with update_time_entry (notes become \
        the billing narrative), then confirm_time_entries once the user agrees. "What haven't I logged" -> \
        evidence kind=unlogged. "Timesheet for Acme" -> timesheet. "How's the budget" -> budget_status.
        To categorize, prefer top_uncategorized -> create_rule over assigning activities one by one. \
        Entries you create are attributed to you as the author.
        Times are ISO 8601; bare dates and datetimes without an offset are the user's local time.
        """

    public static func make(store: Store, now: @escaping () -> Date = Date.init) -> [Tool] {
        // MARK: Argument helpers

        let rangeProps: [String: JSONValue] = [
            "range": ["type": "string", "enum": .array(TimeRange.names.map { .string($0) }),
                      "description": "Named range. Takes precedence over start/end. Defaults to today."],
            "start": ["type": "string", "description": "ISO 8601 date or datetime (inclusive)."],
            "end": ["type": "string", "description": "ISO 8601 date (inclusive of that day) or datetime (exclusive)."],
        ]
        let attributionFilterProps: [String: JSONValue] = [
            "project": ["type": "string", "description": "Only this project (\"Client / Project\" or plain name)."],
            "client": ["type": "string", "description": "Only this client's work."],
            "category": ["type": "string", "description": "Only this category."],
        ]
        let activityFilterProps = attributionFilterProps.merging([
            "sources": ["type": "array", "items": ["type": "string"],
                        "description": "Only these sources, e.g. [\"window\"] or [\"agent:claude-code\"]."],
            "text": ["type": "string", "description": "Substring match on title, app, URL, path or note."],
        ]) { $1 }
        let suggestProps: [String: JSONValue] = [
            "merge_gap_minutes": ["type": "integer", "description": "Merge same project+category blocks this close, absorbing interruptions (default 5)."],
            "min_minutes": ["type": "integer", "description": "Shortest block worth an entry (default 10)."],
            "include_agents": ["type": "boolean", "description": "Count agent sessions as the user's time (default false)."],
        ]
        let entryFields: [String: JSONValue] = [
            "project": ["type": ["string", "null"],
                        "description": "\"Client / Project\" or internal project name; created if missing. null for none."],
            "category": ["type": ["string", "null"], "description": "Existing category name. null for none."],
            "title": ["type": ["string", "null"]],
            "notes": ["type": ["string", "null"], "description": "Billing narrative; shows up in timesheets."],
            "tags": ["type": "array", "items": ["type": "string"]],
            "billable": ["type": "boolean", "description": "Omit to derive from project and category."],
        ]
        let projectFields: [String: JSONValue] = [
            "client": ["type": ["string", "null"], "description": "Client name (created if missing). Omit or null for an internal project."],
            "status": ["type": "string", "enum": .array(ProjectStatus.allCases.map { .string($0.rawValue) }),
                       "description": "prospect = presales, before the deal is won."],
            "billable": ["type": "boolean", "description": "Default: true for client engagements, false for internal projects."],
            "budget_hours": ["type": ["number", "null"]],
            "starts_on": ["type": ["string", "null"], "description": "yyyy-MM-dd"],
            "ends_on": ["type": ["string", "null"], "description": "yyyy-MM-dd"],
            "color": ["type": ["string", "null"], "description": "Hex color, e.g. #3b82f6."],
        ]

        func schema(_ props: [String: JSONValue], required: [String] = []) -> JSONValue {
            ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) }),
             "additionalProperties": false]
        }
        func range(_ a: Arguments) throws -> DateInterval {
            do {
                return try TimeRange.resolve(range: a.string("range"), start: a.string("start"), end: a.string("end"), now: now())
            } catch let e as TimeRange.ParseError { throw ToolError(e.description) }
        }
        func groupBy(_ a: Arguments) throws -> Store.GroupBy {
            let name = try a.string("group_by") ?? "project"
            guard let groupBy = Store.GroupBy(rawValue: name) else { throw ToolError("unknown group_by \"\(name)\"") }
            return groupBy
        }
        func date(_ a: Arguments, _ key: String) throws -> Date? {
            guard let s = try a.string(key) else { return nil }
            guard let d = TimeRange.parseDate(s) else { throw ToolError("can't parse \(key) \"\(s)\" as an ISO 8601 date/datetime") }
            return d
        }
        func requiredID(_ a: Arguments) throws -> Int64 {
            guard let id = try a.int("id") else { throw ToolError("missing required argument \"id\"") }
            return Int64(id)
        }
        func nullableString(_ a: Arguments, _ key: String) throws -> String?? {
            a.has(key) ? .some(try a.string(key)) : nil
        }
        /// nil = not passed; .some(nil) = passed as null.
        func projectArg(_ a: Arguments, create: Bool = true) throws -> Int64?? {
            guard a.has("project") else { return nil }
            return .some(try a.string("project").map { try (create ? store.ensureProject($0) : store.requireProject($0)).id })
        }
        func categoryArg(_ a: Arguments) throws -> Int64?? {
            guard a.has("category") else { return nil }
            return .some(try a.string("category").map { try store.requireCategory(named: $0).id })
        }
        func status(_ a: Arguments) throws -> EntryStatus? {
            guard let s = try a.string("status") else { return nil }
            guard let status = EntryStatus(rawValue: s) else { throw ToolError("unknown status \"\(s)\"; use draft or confirmed") }
            return status
        }
        func activityFilter(_ a: Arguments) throws -> Store.ActivityFilter {
            var f = Store.ActivityFilter()
            f.sources = try a.strings("sources")
            f.projectID = try a.string("project").map { try store.requireProject($0).id }
            f.clientID = try a.string("client").map { try store.requireClient(named: $0).id }
            f.categoryID = try a.string("category").map { try store.requireCategory(named: $0).id }
            f.uncategorizedOnly = try a.bool("uncategorized_only") ?? false
            f.text = try a.string("text")
            return f
        }
        func entryFilter(_ a: Arguments) throws -> Store.EntryFilter {
            var f = Store.EntryFilter()
            f.projectID = try a.string("project").map { try store.requireProject($0).id }
            f.clientID = try a.string("client").map { try store.requireClient(named: $0).id }
            f.categoryID = try a.string("category").map { try store.requireCategory(named: $0).id }
            f.status = try status(a)
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
        func projectStatus(_ a: Arguments) throws -> ProjectStatus? {
            guard let s = try a.string("status") else { return nil }
            guard let status = ProjectStatus(rawValue: s) else { throw ToolError("unknown status \"\(s)\"; use prospect, active or closed") }
            return status
        }
        func budget(_ a: Arguments) throws -> Double?? {
            switch a.values["budget_hours"] {
            case nil: return nil
            case .null?: return .some(nil)
            case .number(let n)?: return .some(n)
            default: throw ToolError("budget_hours must be a number")
            }
        }
        func projectView(_ p: Project, rules: [Rule] = [], catalog: Store.Catalog? = nil) -> ProjectView {
            ProjectView(p, rules: rules.filter { $0.projectID == p.id }.map { RuleView($0, catalog: catalog) })
        }

        return [
            // MARK: Status

            Tool(
                name: "get_status",
                description: "What the user is doing right now: current frontmost activity, running timer, today's unlogged minutes (and how many are billable), and when agent sessions were last imported.",
                inputSchema: schema([:]), readOnly: true
            ) { _, _ in
                let latest = try store.latestActivity(source: Source.window)
                    .flatMap { now().timeIntervalSince($0.end ?? now()) < 60 ? $0 : nil }
                let current = try latest.flatMap { a in
                    try store.activities(in: DateInterval(start: a.start, end: max(a.end ?? now(), a.start + 1)), now: now())
                        .first { $0.id == a.id }
                }
                let unlogged = try store.unloggedTime(in: TimeRange.named("today", now: now())!, groupBy: .project, now: now())
                return Status(
                    now: now(),
                    current: current.map { ActivityView($0, now: now()) },
                    runningTimer: try store.runningEntry().map { EntryView($0, now: now()) },
                    unloggedTodayMinutes: minutes(unlogged.seconds),
                    unloggedTodayBillableMinutes: minutes(unlogged.billableSeconds),
                    lastAgentImport: try store.value(forKey: "ingest.claude-code.last_run")
                        .flatMap(Double.init).map(Date.init(timeIntervalSince1970:)))
            },

            // MARK: Activities

            Tool(
                name: "query_activity",
                description: "List observed activities in a range, oldest first, with resolved client, project and category.",
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
                    Summary: claimed time from time entries in a range, with billable minutes and utilization \
                    (billable / total). Confirmed entries only unless include_drafts. group_by project, client, \
                    category or day. Observed activity is not here: use the evidence tool for that.
                    """,
                inputSchema: schema(rangeProps.merging(attributionFilterProps) { $1 }.merging([
                    "text": ["type": "string", "description": "Substring match on entry title or notes."],
                    "group_by": ["type": "string", "enum": ["project", "client", "category", "day"],
                                 "description": "Default: project."],
                    "include_drafts": ["type": "boolean", "description": "Count draft entries too (default false)."],
                ]) { $1 }),
                readOnly: true
            ) { a, _ in
                if a.has("kind") {
                    throw ToolError("summarize reports time entries only and takes no kind; use the evidence tool for activities or unlogged time")
                }
                let groupBy = try groupBy(a)
                let interval = try range(a)
                var f = try entryFilter(a)
                f.status = nil
                let summary = try store.summary(in: interval, groupBy: groupBy, filter: f,
                                                includeDrafts: try a.bool("include_drafts") ?? false, now: now())
                return SummaryView(start: interval.start, end: interval.end, groupBy: groupBy.rawValue, summary: summary)
            },

            Tool(
                name: "evidence",
                description: """
                    Evidence for claiming time; never claimed time itself. \
                    kind=activities (default): observed activity time in minutes per source (window, agent:*), never \
                    summed across sources; group_by project, client, category, app, source or day. \
                    kind=unlogged: work a suggestion would offer to claim (stretches where one project dominates, \
                    agents excluded) not covered by a confirmed time entry, with billable minutes derived from the \
                    project and category as for time entries; group_by project, client, category or day. \
                    For claimed time use summarize.
                    """,
                inputSchema: schema(rangeProps.merging(activityFilterProps) { $1 }.merging([
                    "kind": ["type": "string", "enum": ["activities", "unlogged"], "description": "Default: activities."],
                    "group_by": ["type": "string", "enum": .array(Store.GroupBy.allCases.map { .string($0.rawValue) }),
                                 "description": "Default: project."],
                ]) { $1 }),
                readOnly: true
            ) { a, _ in
                let groupBy = try groupBy(a)
                let interval = try range(a)
                switch try a.string("kind") ?? "activities" {
                case "activities":
                    let rows = try store.evidence(in: interval, groupBy: groupBy, filter: try activityFilter(a), now: now())
                    return EvidenceTotalsView(start: interval.start, end: interval.end, groupBy: groupBy.rawValue, activities: rows)
                case "unlogged":
                    let unlogged = try store.unloggedTime(in: interval, groupBy: groupBy, now: now())
                    return EvidenceTotalsView(start: interval.start, end: interval.end, groupBy: groupBy.rawValue, unlogged: unlogged)
                case let kind:
                    throw ToolError("unknown kind \"\(kind)\"; use activities or unlogged (time entries are in summarize)")
                }
            },

            Tool(
                name: "top_uncategorized",
                description: "The biggest chunks of activity with no project in a range, grouped by app, website host, or agent working directory, with example titles and any client matched by domain. Use this to propose rules.",
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
                        source: activity.source, field: field, value: value, app: activity.appName,
                        client: activity.client, category: activity.category, minutes: 0, examples: [])
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
                description: "Explicitly set the project and/or category of specific activities, overriding rules. Omit a field to leave it alone; null clears the override.",
                inputSchema: schema([
                    "ids": ["type": "array", "items": ["type": "integer"]],
                    "project": ["type": ["string", "null"]],
                    "category": ["type": ["string", "null"]],
                ], required: ["ids"])
            ) { a, _ in
                let project = try projectArg(a), category = try categoryArg(a)
                guard project != nil || category != nil else { throw ToolError("pass project and/or category") }
                return ["updated": try store.assign(activityIDs: try a.ints("ids") ?? [], projectID: project, categoryID: category)]
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

            // MARK: Clients, projects, categories, rules

            Tool(
                name: "list_clients",
                description: "All clients with their domains and projects.",
                inputSchema: schema(["include_closed": ["type": "boolean", "description": "Include closed projects."]]),
                readOnly: true
            ) { a, _ in
                let projects = try store.projects(includeClosed: try a.bool("include_closed") ?? false)
                return try store.clients().map { c in
                    ClientView(name: c.name, domains: c.domains,
                               projects: projects.filter { $0.clientID == c.id }.map { projectView($0) })
                }
            },

            Tool(
                name: "create_client",
                description: "Create a client, or add domains to an existing one. Domains (acme.com) attribute matching URLs to the client.",
                inputSchema: schema([
                    "name": ["type": "string"],
                    "domains": ["type": "array", "items": ["type": "string"]],
                ], required: ["name"])
            ) { a, _ in
                let c = try store.ensureClient(named: try a.requiredString("name"), addingDomains: try a.strings("domains") ?? [])
                return ClientView(name: c.name, domains: c.domains, projects: [])
            },

            Tool(
                name: "list_projects",
                description: "Projects (client engagements and internal projects) with status, budget and attribution rules.",
                inputSchema: schema([
                    "client": ["type": "string", "description": "Only this client's engagements."],
                    "include_closed": ["type": "boolean"],
                ]),
                readOnly: true
            ) { a, _ in
                let client = try a.string("client").map { try store.requireClient(named: $0).id }
                let rules = try store.rules()
                let catalog = try store.catalog()
                return try store.projects(includeClosed: try a.bool("include_closed") ?? false, clientID: client)
                    .map { projectView($0, rules: rules, catalog: catalog) }
            },

            Tool(
                name: "create_project",
                description: "Create a client engagement (pass client) or an internal project. Fails if it already exists; use update_project to change one.",
                inputSchema: schema(projectFields.merging(["name": ["type": "string"]]) { $1 }, required: ["name"])
            ) { a, _ in
                let client = try a.string("client").map { try store.ensureClient(named: $0).id }
                let p = try store.createProject(
                    name: try a.requiredString("name"), clientID: client, status: try projectStatus(a) ?? .active,
                    billable: try a.bool("billable"), budgetHours: try budget(a) ?? nil,
                    startsOn: try a.string("starts_on"), endsOn: try a.string("ends_on"), color: try a.string("color"))
                return projectView(p)
            },

            Tool(
                name: "update_project",
                description: "Change a project: rename, move to a client, change status (e.g. prospect -> active when the deal is won), billable default, budget or dates. Omitted fields are left alone; null clears.",
                inputSchema: schema(projectFields.merging([
                    "project": ["type": "string", "description": "\"Client / Project\" or plain name."],
                    "name": ["type": "string", "description": "New name."],
                ]) { $1 }, required: ["project"])
            ) { a, _ in
                let p = try store.requireProject(try a.requiredString("project"))
                var changes = ProjectChanges()
                changes.name = try a.string("name")
                if a.has("client") { changes.clientID = .some(try a.string("client").map { try store.ensureClient(named: $0).id }) }
                changes.status = try projectStatus(a)
                changes.billable = try a.bool("billable")
                changes.budgetHours = try budget(a)
                changes.startsOn = try nullableString(a, "starts_on")
                changes.endsOn = try nullableString(a, "ends_on")
                changes.color = try nullableString(a, "color")
                return projectView(try store.updateProject(id: p.id, changes))
            },

            Tool(
                name: "list_categories",
                description: "Categories (kinds of work) and whether each can be billable.",
                inputSchema: schema([:]), readOnly: true
            ) { _, _ in
                try store.categories().map { CategoryView(name: $0.name, billable: $0.billable) }
            },

            Tool(
                name: "create_category",
                description: "Create a category (kind of work). billable=false makes it never billable, even on billable projects (e.g. presales).",
                inputSchema: schema(["name": ["type": "string"], "billable": ["type": "boolean", "description": "Default true."]],
                                    required: ["name"])
            ) { a, _ in
                let c = try store.createCategory(named: try a.requiredString("name"), billable: try a.bool("billable") ?? true)
                return CategoryView(name: c.name, billable: c.billable)
            },

            Tool(
                name: "create_rule",
                description: """
                    Attribute matching activities to a project and/or category, retroactively and going forward. \
                    Project and category resolve independently, so "app_name equals Zoom -> category Meetings" and \
                    "title contains Acme -> project Acme / Phase 2" combine. Matching is case-insensitive. Returns how \
                    many activities in the last 30 days the rule now decides.
                    """,
                inputSchema: schema([
                    "project": ["type": "string", "description": "\"Client / Project\" or internal project name; created if missing."],
                    "category": ["type": "string", "description": "Existing category name."],
                    "field": ["type": "string", "enum": .array(RuleField.allCases.map { .string($0.rawValue) }),
                              "description": "bundle_id (e.g. com.apple.Safari), app_name, title, url, path (document path or agent working dir), source."],
                    "op": ["type": "string", "enum": .array(RuleOp.allCases.map { .string($0.rawValue) })],
                    "pattern": ["type": "string"],
                    "priority": ["type": "integer", "description": "Higher wins when rules conflict. Default 0."],
                ], required: ["field", "op", "pattern"])
            ) { a, _ in
                let project = try projectArg(a) ?? nil
                let category = try categoryArg(a) ?? nil
                guard project != nil || category != nil else { throw ToolError("a rule needs a project, a category, or both") }
                let fieldName = try a.requiredString("field"), opName = try a.requiredString("op")
                guard let field = RuleField(rawValue: fieldName) else { throw ToolError("unknown field \"\(fieldName)\"") }
                guard let op = RuleOp(rawValue: opName) else { throw ToolError("unknown op \"\(opName)\"") }
                let rule = try store.addRule(projectID: project, categoryID: category, field: field, op: op,
                                             pattern: try a.requiredString("pattern"), priority: try a.int("priority") ?? 0)
                let recent = try store.activities(in: TimeRange.named("last_30_days", now: now())!, now: now())
                let engine = RuleEngine(rules: try store.rules())
                let decided = recent.filter { activity in
                    (project != nil && activity.assignedProjectID == nil && engine.projectRule(for: activity)?.id == rule.id)
                        || (category != nil && activity.assignedCategoryID == nil && engine.categoryRule(for: activity)?.id == rule.id)
                }
                return CreatedRule(rule: RuleView(rule, catalog: try store.catalog()), matchedLast30Days: decided.count,
                                   minutesLast30Days: minutes(decided.reduce(0) { $0 + $1.duration(now: now()) }))
            },

            Tool(
                name: "delete_rule",
                description: "Delete an attribution rule by id.",
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
                inputSchema: schema(rangeProps.merging(attributionFilterProps) { $1 }.merging([
                    "status": ["type": "string", "enum": ["draft", "confirmed"], "description": "Default: both."],
                    "text": ["type": "string", "description": "Substring match on title, notes or tags."],
                ]) { $1 }),
                readOnly: true
            ) { a, _ in
                try store.timeEntries(in: try range(a), filter: try entryFilter(a), now: now()).map { EntryView($0, now: now()) }
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
                new.projectID = try projectArg(a) ?? nil
                new.categoryID = try categoryArg(a) ?? nil
                new.title = try a.string("title")
                new.notes = try a.string("notes")
                new.tags = try a.strings("tags") ?? []
                new.billable = try a.bool("billable")
                new.author = ctx.author
                new.status = try status(a) ?? .confirmed
                return EntryView(try store.createEntry(new, now: now()), now: now())
            },

            Tool(
                name: "update_time_entry",
                description: "Change fields of a time entry. Omitted fields are left alone; null clears project/category/title/notes. Changing project or category re-derives billable unless billable is passed.",
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
                changes.projectID = try projectArg(a)
                changes.categoryID = try categoryArg(a)
                changes.title = try nullableString(a, "title")
                changes.notes = try nullableString(a, "notes")
                changes.tags = try a.strings("tags")
                changes.billable = try a.bool("billable")
                changes.status = try status(a)
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
                    Draft time entries from attributed activities in a range: contiguous work on one project and \
                    category becomes one draft, short interruptions are absorbed, and time already covered by entries \
                    is skipped. Re-running replaces earlier suggestions in the range. Returns drafts with the evidence \
                    behind each; write titles/notes with update_time_entry, then confirm_time_entries when the user \
                    agrees. Activity with no project is ignored, so attribute first (top_uncategorized -> create_rule).
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
                description: "Confirm draft time entries so they count in timesheets and reports.",
                inputSchema: schema(["ids": ["type": "array", "items": ["type": "integer"]]], required: ["ids"])
            ) { a, _ in
                ["confirmed": try store.setStatus(entryIDs: try a.ints("ids") ?? [], .confirmed, now: now())]
            },

            Tool(
                name: "start_timer",
                description: "Start a running time entry, stopping any running one.",
                inputSchema: schema([
                    "project": ["type": "string"], "category": ["type": "string"],
                    "title": ["type": "string"], "notes": ["type": "string"],
                ])
            ) { a, ctx in
                let result = try store.startTimer(
                    projectID: try projectArg(a) ?? nil, categoryID: try categoryArg(a) ?? nil,
                    title: try a.string("title"), notes: try a.string("notes"), author: ctx.author, now: now())
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

            // MARK: Reports

            Tool(
                name: "budget_status",
                description: "Hours used against budget for engagements, most-burned first: confirmed hours, billable hours, unconfirmed draft hours, remaining, and burn (used/budget).",
                inputSchema: schema([
                    "project": ["type": "string", "description": "One project (included even without a budget)."],
                    "client": ["type": "string", "description": "All of this client's open projects."],
                ]),
                readOnly: true
            ) { a, _ in
                var ids: [Int64]?
                if let ref = try a.string("project") { ids = [try store.requireProject(ref).id] }
                if let name = try a.string("client") {
                    ids = try store.projects(clientID: try store.requireClient(named: name).id).map(\.id)
                }
                return try store.budgetStatus(projectIDs: ids, now: now()).map(BudgetView.init)
            },

            Tool(
                name: "timesheet",
                description: "Confirmed time as one row per day, project and category, with hours, billable hours and the entries' titles/notes as the narrative. format=csv returns CSV ready to import into a PSA/timesheet tool.",
                inputSchema: schema(rangeProps.merging(attributionFilterProps) { $1 }.merging([
                    "include_drafts": ["type": "boolean", "description": "Include unconfirmed drafts (default false)."],
                    "format": ["type": "string", "enum": ["json", "csv"]],
                ]) { $1 }),
                readOnly: true
            ) { a, _ in
                var f = try entryFilter(a)
                f.status = nil
                let rows = try store.timesheet(in: try range(a), filter: f, includeDrafts: try a.bool("include_drafts") ?? false, now: now())
                if try a.string("format") == "csv" { return Store.csv(rows) }
                return rows.map(TimesheetView.init)
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
                    "category": ["type": "string", "description": "Optional explicit category."],
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
                let project = try projectArg(a), category = try categoryArg(a)
                try store.upsertExternal(source: source, externalID: externalID, start: start, end: end,
                                         title: try a.requiredString("title"), path: try a.string("path"))
                let row = try store.db.query("SELECT id FROM activities WHERE source = ? AND external_id = ?", [source, externalID])
                let id = row.first!.int("id")!
                if project != nil || category != nil {
                    try store.assign(activityIDs: [id], projectID: project, categoryID: category)
                }
                let resolved = try store.activities(in: DateInterval(start: start, end: max(end, start + 1)), now: now())
                    .first { $0.id == id }
                return ActivityView(try resolved ?? store.activity(id: id)!, now: now())
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
    static func hours(_ hours: Double) -> Double { (hours * 100).rounded() / 100 }
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
    var client: String?
    var project: String?
    var projectFrom: String?
    var category: String?
    var categoryFrom: String?

    init(_ a: Activity, now: Date) {
        id = a.id; start = a.start; end = a.end; minutes = WaidTools.minutes(a.duration(now: now))
        source = a.source; app = a.appName; bundleID = a.bundleID; title = a.title; url = a.url; path = a.path
        client = a.client; project = a.project; category = a.category
        projectFrom = a.assignedProjectID != nil ? "assigned" : (a.projectID != nil ? "rule" : nil)
        categoryFrom = a.assignedCategoryID != nil ? "assigned" : (a.categoryID != nil ? "rule" : nil)
    }

    enum CodingKeys: String, CodingKey {
        case id, start, end, minutes, source, app, title, url, path, client, project, category
        case bundleID = "bundle_id", projectFrom = "project_from", categoryFrom = "category_from"
    }
}

struct EntryView: Encodable {
    var id: Int64
    var start: Date
    var end: Date?
    var minutes: Double
    var client: String?
    var project: String?
    var category: String?
    var title: String?
    var notes: String?
    var tags: [String]
    var billable: Bool
    var origin: String
    var author: String
    var status: String

    init(_ e: TimeEntry, now: Date) {
        id = e.id; start = e.start; end = e.end; minutes = WaidTools.minutes(e.duration(now: now))
        client = e.client; project = e.project; category = e.category
        title = e.title; notes = e.notes; tags = e.tags; billable = e.billable
        origin = e.origin.rawValue; author = e.author; status = e.status.rawValue
    }
}

struct Status: Encodable {
    var now: Date
    var current: ActivityView?
    var runningTimer: EntryView?
    var unloggedTodayMinutes: Double
    var unloggedTodayBillableMinutes: Double
    var lastAgentImport: Date?
    enum CodingKeys: String, CodingKey {
        case now, current, runningTimer = "running_timer", unloggedTodayMinutes = "unlogged_today_minutes"
        case unloggedTodayBillableMinutes = "unlogged_today_billable_minutes"
        case lastAgentImport = "last_agent_import"
    }
}

struct TimeGroupView: Encodable {
    var key: String
    var minutes: Double
    var billableMinutes: Double?
    enum CodingKeys: String, CodingKey { case key, minutes, billableMinutes = "billable_minutes" }
}

/// A Summary: claimed time from time entries.
struct SummaryView: Encodable {
    var start: Date
    var end: Date
    var groupBy: String
    var groups: [TimeGroupView]
    var totalMinutes: Double
    var billableMinutes: Double
    /// Billable / total, or nil with no time.
    var utilization: Double?

    init(start: Date, end: Date, groupBy: String, summary: Store.Summary) {
        self.start = start; self.end = end; self.groupBy = groupBy
        groups = summary.groups.map {
            TimeGroupView(key: $0.key, minutes: WaidTools.minutes($0.seconds), billableMinutes: WaidTools.minutes($0.billableSeconds))
        }
        totalMinutes = WaidTools.minutes(summary.seconds)
        billableMinutes = WaidTools.minutes(summary.billableSeconds)
        utilization = summary.utilization.map { ($0 * 1000).rounded() / 1000 }
    }

    enum CodingKeys: String, CodingKey {
        case start, end, groups, utilization, groupBy = "group_by", totalMinutes = "total_minutes"
        case billableMinutes = "billable_minutes"
    }
}

/// Evidence for claiming time: observed activity per source, or Unlogged time.
struct EvidenceTotalsView: Encodable {
    struct ActivityGroup: Encodable {
        var key: String
        var minutesBySource: [String: Double]
        enum CodingKeys: String, CodingKey { case key, minutesBySource = "minutes_by_source" }
    }

    var start: Date
    var end: Date
    var kind: String
    var groupBy: String
    var activityGroups: [ActivityGroup]?
    var unloggedGroups: [TimeGroupView]?
    /// Unlogged time only: activity totals per source have no single total.
    var totalMinutes: Double?
    var billableMinutes: Double?

    init(start: Date, end: Date, groupBy: String, activities: [Store.EvidenceRow]) {
        self.start = start; self.end = end; self.groupBy = groupBy; kind = "activities"
        activityGroups = activities.map { ActivityGroup(key: $0.key, minutesBySource: $0.secondsBySource.mapValues(WaidTools.minutes)) }
    }

    init(start: Date, end: Date, groupBy: String, unlogged: Store.UnloggedTime) {
        self.start = start; self.end = end; self.groupBy = groupBy; kind = "unlogged"
        unloggedGroups = unlogged.groups.map {
            TimeGroupView(key: $0.key, minutes: WaidTools.minutes($0.seconds), billableMinutes: WaidTools.minutes($0.billableSeconds))
        }
        totalMinutes = WaidTools.minutes(unlogged.seconds)
        billableMinutes = WaidTools.minutes(unlogged.billableSeconds)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(kind, forKey: .kind)
        try c.encode(groupBy, forKey: .groupBy)
        if let activityGroups { try c.encode(activityGroups, forKey: .groups) }
        if let unloggedGroups { try c.encode(unloggedGroups, forKey: .groups) }
        try c.encodeIfPresent(totalMinutes, forKey: .totalMinutes)
        try c.encodeIfPresent(billableMinutes, forKey: .billableMinutes)
    }

    enum CodingKeys: String, CodingKey {
        case start, end, kind, groups, groupBy = "group_by", totalMinutes = "total_minutes"
        case billableMinutes = "billable_minutes"
    }
}

struct UncategorizedGroup: Encodable {
    var source: String
    var field: String
    var value: String
    var app: String?
    var client: String?
    var category: String?
    var minutes: Double
    var examples: [String]
}

struct RuleView: Encodable {
    var id: Int64
    var project: String?
    var category: String?
    var field: String
    var op: String
    var pattern: String
    var priority: Int
    init(_ r: Rule, catalog: Store.Catalog?) {
        id = r.id; field = r.field.rawValue; op = r.op.rawValue; pattern = r.pattern; priority = r.priority
        project = r.projectID.flatMap { catalog?.projects[$0]?.path }
        category = r.categoryID.flatMap { catalog?.categories[$0]?.name }
    }
}

struct ProjectView: Encodable {
    var id: Int64
    var name: String
    var path: String
    var client: String?
    var status: String
    var billable: Bool
    var budgetHours: Double?
    var startsOn: String?
    var endsOn: String?
    var color: String?
    var rules: [RuleView]

    init(_ p: Project, rules: [RuleView]) {
        id = p.id; name = p.name; path = p.path; client = p.client; status = p.status.rawValue
        billable = p.billable; budgetHours = p.budgetHours; startsOn = p.startsOn; endsOn = p.endsOn
        color = p.color; self.rules = rules
    }

    enum CodingKeys: String, CodingKey {
        case id, name, path, client, status, billable, color, rules
        case budgetHours = "budget_hours", startsOn = "starts_on", endsOn = "ends_on"
    }
}

struct ClientView: Encodable {
    var name: String
    var domains: [String]
    var projects: [ProjectView]
}

struct CategoryView: Encodable {
    var name: String
    var billable: Bool
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

struct BudgetView: Encodable {
    var project: String
    var client: String?
    var status: String
    var budgetHours: Double?
    var usedHours: Double
    var billableHours: Double
    var draftHours: Double
    var remainingHours: Double?
    var burn: Double?
    var endsOn: String?

    init(_ r: Store.BudgetRow) {
        project = r.project; client = r.client; status = r.status.rawValue; budgetHours = r.budgetHours
        usedHours = WaidTools.hours(r.usedHours); billableHours = WaidTools.hours(r.billableHours)
        draftHours = WaidTools.hours(r.draftHours); remainingHours = r.remainingHours.map(WaidTools.hours)
        burn = r.burn.map { ($0 * 1000).rounded() / 1000 }; endsOn = r.endsOn
    }

    enum CodingKeys: String, CodingKey {
        case project, client, status, burn
        case budgetHours = "budget_hours", usedHours = "used_hours", billableHours = "billable_hours"
        case draftHours = "draft_hours", remainingHours = "remaining_hours", endsOn = "ends_on"
    }
}

struct TimesheetView: Encodable {
    var date: String
    var client: String?
    var project: String?
    var category: String?
    var hours: Double
    var billableHours: Double
    var notes: [String]

    init(_ r: Store.TimesheetRow) {
        date = r.date; client = r.client; project = r.project; category = r.category
        hours = WaidTools.hours(r.hours); billableHours = WaidTools.hours(r.billableHours); notes = r.notes
    }

    enum CodingKeys: String, CodingKey {
        case date, client, project, category, hours, notes, billableHours = "billable_hours"
    }
}
