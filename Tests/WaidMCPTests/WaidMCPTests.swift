import Foundation
import XCTest
import WaidCore
@testable import WaidMCP

final class MCPServerTests: XCTestCase {
    var store: Store!
    var server: MCPServer!
    var now = TimeRange.parseDate("2026-10-09T15:00:00Z")!

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
        server = MCPServer(name: "waid", version: "test", instructions: WaidTools.instructions,
                           tools: WaidTools.make(store: store, now: { [unowned self] in self.now }))
    }

    private func send(_ json: String) throws -> JSONValue {
        let line = try XCTUnwrap(server.handle(line: json))
        return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    /// Calls a tool and returns its decoded JSON text output.
    private func call(_ name: String, _ arguments: JSONValue = [:], expectError: Bool = false) throws -> JSONValue {
        let request: JSONValue = ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                  "params": ["name": .string(name), "arguments": arguments]]
        let response = try send(String(decoding: try JSONEncoder().encode(request), as: UTF8.self))
        let result = try XCTUnwrap(response["result"], "\(response)")
        XCTAssertEqual(result["isError"], .bool(expectError), "\(result)")
        guard case .array(let content)? = result["content"], let text = content.first?["text"]?.stringValue else {
            XCTFail("no text content"); return .null
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
    }

    func testHandshake() throws {
        let initialized = try send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        XCTAssertEqual(initialized["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertEqual(initialized["result"]?["serverInfo"]?["name"], "waid")
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))

        let unknownVersion = try send(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(unknownVersion["result"]?["protocolVersion"], .string(MCPServer.supportedProtocolVersions[0]))

        let list = try send(#"{"jsonrpc":"2.0","id":"abc","method":"tools/list"}"#)
        XCTAssertEqual(list["id"], "abc")
        guard case .array(let tools)? = list["result"]?["tools"] else { return XCTFail("no tools") }
        XCTAssertTrue(tools.contains { $0["name"] == "summarize" })
        XCTAssertTrue(tools.contains { $0["name"] == "evidence" })
        XCTAssertTrue(tools.allSatisfy { $0["inputSchema"]?["type"] == "object" })

        XCTAssertEqual(try send(#"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)["error"]?["code"], -32601)
        XCTAssertEqual(try send("{not json")["error"]?["code"], -32700)
    }

    func testCategorizeFlow() throws {
        let t = now.addingTimeInterval(-3600)
        try store.work(ActivitySample(bundleID: "com.apple.Safari", appName: "Safari",
                                      title: "waid PR", url: "https://github.com/tarqd/waid/pull/2"),
                       from: t, to: t + 1200)
        try store.work(ActivitySample(bundleID: "com.apple.Terminal", appName: "Terminal", title: "zsh"),
                       from: t + 1200, to: t + 1800)

        let top = try call("top_uncategorized", ["range": "today"])
        guard case .array(let groups) = top else { return XCTFail("\(top)") }
        XCTAssertEqual(groups.first?["field"], "url")
        XCTAssertEqual(groups.first?["value"], "github.com")
        XCTAssertEqual(groups.first?["minutes"], 20)

        let created = try call("create_rule", ["project": "waid", "field": "url", "op": "contains", "pattern": "tarqd/waid"])
        XCTAssertEqual(created["matched_last_30_days"], 1)
        XCTAssertEqual(created["minutes_last_30_days"], 20)

        let evidence = try call("evidence", ["range": "today"])
        XCTAssertEqual(evidence["kind"], "activities")
        guard case .array(let rows)? = evidence["groups"] else { return XCTFail("\(evidence)") }
        XCTAssertEqual(rows.first?["key"], "waid")
        XCTAssertEqual(rows.first?["minutes_by_source"], ["window": 20])
        XCTAssertNil(rows.first?["minutes"], "observed time is per source, never a single total")
        XCTAssertEqual(rows.last?["key"], "(no project)")
        XCTAssertNil(evidence["total_minutes"])
        XCTAssertEqual(try call("evidence", ["range": "today", "group_by": "app"])["groups"],
                       [["key": "Safari", "minutes_by_source": ["window": 20]],
                        ["key": "Terminal", "minutes_by_source": ["window": 10]]])

        XCTAssertEqual(try call("summarize", ["range": "today"])["groups"], [], "activities are not claimed time")

        _ = try call("create_rule", ["field": "url", "op": "contains", "pattern": "x"], expectError: true)
        _ = try call("create_rule", ["category": "Nope", "field": "url", "op": "contains", "pattern": "x"], expectError: true)
        _ = try call("summarize", ["range": "fortnight"], expectError: true)
        _ = try call("evidence", ["kind": "entries"], expectError: true)
    }

    func testTimersAndAgentWork() throws {
        let started = try call("start_timer", ["project": "Writing", "title": "blog"])
        XCTAssertEqual(started["started"]?["project"], "Writing")
        XCTAssertEqual(started["started"]?["origin"], "timer")
        now += 600
        XCTAssertEqual(try call("get_status")["running_timer"]?["minutes"], 10)
        XCTAssertEqual(try call("stop_timer")["minutes"], 10)
        XCTAssertEqual(try call("stop_timer"), "no timer running")

        let args: JSONValue = ["agent": "codex", "start": "2026-10-09T14:00:00Z", "end": "2026-10-09T14:30:00Z",
                               "title": "refactor", "path": "/src/waid", "external_id": "run-1"]
        _ = try call("record_agent_work", args)
        var updated = args.objectValue!
        updated["end"] = "2026-10-09T14:45:00Z"
        let again = try call("record_agent_work", .object(updated))
        XCTAssertEqual(again["minutes"], 45)

        let agentSpans = try call("query_activity", ["range": "today", "sources": ["agent:codex"]])
        guard case .array(let spans) = agentSpans else { return XCTFail("\(agentSpans)") }
        XCTAssertEqual(spans.count, 1, "same external_id updates instead of duplicating")

        _ = try call("record_agent_work", ["agent": "bad name!", "start": "2026-10-09", "title": "x"], expectError: true)
    }

    func testTimeEntriesTakeAZoneOrTheZoneWhereYouWere() throws {
        store.processZone = TimeZone(identifier: "America/New_York")!
        // 22:00Z on the 9th is the 10th in Tokyo and still the 9th in New York.
        let early = TimeRange.parseDate("2026-10-09T13:00:00Z")!
        try store.work(ActivitySample(appName: "Xcode"),
                       from: early, to: early + 600, zone: TimeZone(identifier: "Asia/Tokyo")!)
        now = TimeRange.parseDate("2026-10-10T03:00:00Z")!

        let unzoned = try call("create_time_entry", ["start": "2026-10-09T22:00:00Z", "end": "2026-10-09T22:30:00Z"])
        XCTAssertEqual(unzoned["zone"], "Asia/Tokyo")
        XCTAssertEqual(unzoned["start_date"], "2026-10-10")

        let zoned = try call("create_time_entry", ["start": "2026-10-09T23:00:00Z", "end": "2026-10-09T23:30:00Z",
                                                   "zone": "America/New_York"])
        XCTAssertEqual(zoned["zone"], "America/New_York")
        XCTAssertEqual(zoned["start_date"], "2026-10-09")
        XCTAssertEqual(zoned["end_date"], "2026-10-09")

        let moved = try call("update_time_entry", ["id": zoned["id"]!, "zone": "Asia/Tokyo"])
        XCTAssertEqual(moved["zone"], "Asia/Tokyo")
        XCTAssertEqual(moved["start_date"], "2026-10-10")

        for tool in ["create_time_entry", "update_time_entry"] {
            let error = try call(tool, ["id": zoned["id"]!, "start": "2026-10-09T20:00:00Z", "end": "2026-10-09T20:30:00Z",
                                        "zone": "Mars/Olympus_Mons"], expectError: true)
            XCTAssertTrue(error.stringValue?.contains("zone") == true, "names the argument: \(error)")
        }
    }

    func testAnEntryWithNoObservationsTakesTheProcessZone() throws {
        store.processZone = TimeZone(identifier: "America/New_York")!
        now = TimeRange.parseDate("2026-10-10T03:00:00Z")!
        let entry = try call("create_time_entry", ["start": "2026-10-09T22:00:00Z", "end": "2026-10-09T22:30:00Z"])
        XCTAssertEqual(entry["zone"], "America/New_York")
        XCTAssertEqual(entry["start_date"], "2026-10-09")
    }

    func testAgentWorkTakesTheZoneWhereYouWereAndStaysIdempotent() throws {
        store.processZone = TimeZone(identifier: "UTC")!
        let early = TimeRange.parseDate("2026-10-09T13:00:00Z")!
        try store.work(ActivitySample(appName: "Xcode"),
                       from: early, to: early + 600, zone: TimeZone(identifier: "Asia/Tokyo")!)
        now = TimeRange.parseDate("2026-10-10T03:00:00Z")!

        let args: JSONValue = ["agent": "codex", "start": "2026-10-09T22:00:00Z", "end": "2026-10-09T22:30:00Z",
                               "title": "refactor", "external_id": "run-1"]
        let first = try call("record_agent_work", args)
        let again = try call("record_agent_work", args)
        XCTAssertEqual(again["id"], first["id"])
        XCTAssertEqual(again["zone"], "Asia/Tokyo")
        XCTAssertEqual(again["local_date"], "2026-10-10")

        // Two sessions' transcripts with UTC timestamps.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectDir = dir.appendingPathComponent("projects/-src-waid")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("""
            {"type":"user","sessionId":"s1","cwd":"/src/waid","timestamp":"2026-10-09T23:00:00Z","message":{"role":"user","content":"fix"}}
            {"type":"assistant","sessionId":"s1","cwd":"/src/waid","timestamp":"2026-10-09T23:10:00Z","message":{"role":"assistant","content":"ok"}}
            """.utf8).write(to: projectDir.appendingPathComponent("s1.jsonl"))
        setenv("CLAUDE_CONFIG_DIR", dir.path, 1)
        defer { unsetenv("CLAUDE_CONFIG_DIR") }

        XCTAssertEqual(try call("import_agent_sessions")["segmentsUpserted"], 1)
        XCTAssertEqual(try call("import_agent_sessions", ["full": true])["segmentsUpserted"], 1)

        let imported = try call("query_activity", ["start": "2026-10-09T00:00:00Z", "end": "2026-10-11T00:00:00Z",
                                                   "sources": ["agent:claude-code"]])
        guard case .array(let spans) = imported else { return XCTFail("\(imported)") }
        XCTAssertEqual(spans.count, 1, "re-importing doesn't duplicate")
        XCTAssertEqual(spans.first?["zone"], "Asia/Tokyo")
        XCTAssertEqual(spans.first?["local_date"], "2026-10-10")
    }

    func testSuggestEditConfirmFlowAttributesAgent() throws {
        _ = try send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"Claude Code","version":"2"}}}"#)
        let t = TimeRange.parseDate("2026-10-09T09:00:00Z")!
        try store.work(ActivitySample(appName: "Xcode", title: "Store.swift", path: "/src/waid/Store.swift"),
                       from: t, to: t + 3600)
        _ = try call("create_rule", ["project": "waid", "field": "path", "op": "prefix", "pattern": "/src/waid"])

        let unlogged = try call("evidence", ["range": "today", "kind": "unlogged"])
        XCTAssertEqual(unlogged["kind"], "unlogged")
        XCTAssertEqual(unlogged["groups"], [["key": "waid", "minutes": 60, "billable_minutes": 0]])
        XCTAssertEqual(unlogged["total_minutes"], 60)
        XCTAssertEqual(unlogged["billable_minutes"], 0, "waid is internal")
        XCTAssertEqual(try call("get_status")["unlogged_today_minutes"], 60)
        XCTAssertEqual(try call("get_status")["unlogged_today_billable_minutes"], 0)

        let suggested = try call("suggest_time_entries", ["range": "today"])
        guard case .array(let drafts) = suggested, drafts.count == 1, let draft = drafts.first?["entry"] else {
            return XCTFail("\(suggested)")
        }
        XCTAssertEqual(draft["status"], "draft")
        XCTAssertEqual(draft["author"], "agent:claude-code")
        XCTAssertEqual(draft["title"], "Store.swift")
        XCTAssertEqual(drafts.first?["contributors"], [["label": "Store.swift", "minutes": 60]])
        XCTAssertEqual(try call("summarize", ["range": "today"])["groups"], [], "drafts excluded by default")
        XCTAssertEqual(try call("summarize", ["range": "today", "include_drafts": true])["groups"],
                       [["key": "waid", "minutes": 60, "billable_minutes": 0]])

        let id = try XCTUnwrap(draft["id"])
        let updated = try call("update_time_entry", ["id": id, "title": "Store refactor", "billable": true])
        XCTAssertEqual(updated["title"], "Store refactor")
        XCTAssertEqual(try call("confirm_time_entries", ["ids": [id]])["confirmed"], 1)

        XCTAssertEqual(try call("summarize", ["range": "today"])["groups"],
                       [["key": "waid", "minutes": 60, "billable_minutes": 60]])
        XCTAssertEqual(try call("evidence", ["range": "today", "kind": "unlogged"])["groups"], [])
        XCTAssertEqual(try call("get_status")["unlogged_today_minutes"], 0)

        let overlap = try call("create_time_entry", ["start": "2026-10-09T09:30:00Z", "end": "2026-10-09T10:30:00Z"],
                               expectError: true)
        XCTAssertTrue(overlap.stringValue?.contains("can't overlap") == true, "\(overlap)")
        _ = try call("summarize", ["group_by": "app"], expectError: true)
        _ = try call("evidence", ["kind": "unlogged", "group_by": "source"], expectError: true)
        let oldKind = try call("summarize", ["kind": "activities"], expectError: true)
        XCTAssertTrue(oldKind.stringValue?.contains("evidence") == true, "\(oldKind)")
    }

    func testProfessionalServicesFlow() throws {
        _ = try call("create_client", ["name": "Acme", "domains": ["acme.com"]])
        let project = try call("create_project", ["name": "Phase 2", "client": "Acme", "budget_hours": 20])
        XCTAssertEqual(project["path"], "Acme / Phase 2")
        XCTAssertEqual(project["billable"], true)
        _ = try call("create_project", ["name": "Phase 2", "client": "Acme"], expectError: true)
        _ = try call("create_project", ["name": "Opportunity", "client": "Beta", "status": "prospect"])

        let meeting = try call("create_time_entry", ["start": "2026-10-09T09:00:00Z", "end": "2026-10-09T10:00:00Z",
                                                     "project": "Acme / Phase 2", "category": "Meetings", "title": "kickoff"])
        XCTAssertEqual(meeting["client"], "Acme")
        XCTAssertEqual(meeting["billable"], true)
        let demo = try call("create_time_entry", ["start": "2026-10-09T10:00:00Z", "end": "2026-10-09T11:00:00Z",
                                                  "project": "Beta / Opportunity", "category": "Presales", "title": "demo"])
        XCTAssertEqual(demo["billable"], false)
        _ = try call("create_time_entry", ["start": "2026-10-09T12:00:00Z", "end": "2026-10-09T13:00:00Z",
                                           "category": "Typo"], expectError: true)

        let summary = try call("summarize", ["range": "today", "group_by": "client"])
        XCTAssertEqual(summary["utilization"], .number(0.5))
        XCTAssertEqual(summary["total_minutes"], 120)
        XCTAssertEqual(summary["billable_minutes"], 60)
        XCTAssertEqual(summary["groups"], [["key": "Acme", "minutes": 60, "billable_minutes": 60],
                                           ["key": "Beta", "minutes": 60, "billable_minutes": 0]])

        let budget = try call("budget_status", ["client": "Acme"])
        XCTAssertEqual(budget, [["project": "Acme / Phase 2", "client": "Acme", "status": "active", "budget_hours": 20,
                                 "used_hours": 1, "billable_hours": 1, "draft_hours": 0, "remaining_hours": 19,
                                 "burn": .number(0.05)]])

        let won = try call("update_project", ["project": "Beta / Opportunity", "status": "active", "name": "Rollout"])
        XCTAssertEqual(won["path"], "Beta / Rollout")

        let csv = try call("timesheet", ["range": "today", "client": "Beta", "format": "csv"])
        XCTAssertEqual(csv, "date,client,project,category,hours,billable_hours,notes\n2026-10-09,Beta,Rollout,Presales,1.00,0.00,demo\n")
    }

    func testUnloggedTimeShowsBillableMinutes() throws {
        let t = now.addingTimeInterval(-3 * 3600)
        _ = try call("create_project", ["name": "Phase 2", "client": "Acme"])
        _ = try call("create_rule", ["project": "Acme / Phase 2", "field": "title", "op": "contains", "pattern": "acme"])
        _ = try call("create_rule", ["category": "Presales", "field": "app_name", "op": "equals", "pattern": "Keynote"])
        try store.work(ActivitySample(appName: "Xcode", title: "acme-integration"),
                       from: t, to: t + 3600)
        try store.work(ActivitySample(appName: "Keynote", title: "Acme pitch"),
                       from: t + 3600, to: t + 5400)

        let unlogged = try call("evidence", ["range": "today", "kind": "unlogged"])
        XCTAssertEqual(unlogged["groups"], [["key": "Acme / Phase 2", "minutes": 90, "billable_minutes": 60]])
        XCTAssertEqual(unlogged["total_minutes"], 90)
        XCTAssertEqual(unlogged["billable_minutes"], 60, "presales is never billable")
        let status = try call("get_status")
        XCTAssertEqual(status["unlogged_today_minutes"], 90)
        XCTAssertEqual(status["unlogged_today_billable_minutes"], 60)
    }

    func testRangesAreLocalDatesWhereYouAre() throws {
        // now is Saturday 00:00 in Tokyo, still Friday in UTC.
        try store.recordZone(TimeZone(identifier: "Asia/Tokyo")!, now: now - 7 * 86400)
        let acme = try store.ensureProject("Acme / Phase 2")
        for start in [now - 3600, now] {
            try store.createEntry(NewTimeEntry(start: start, end: start + 1800, projectID: acme.id, origin: .manual), now: now)
        }

        let today = try call("summarize", ["range": "today", "group_by": "day"])
        XCTAssertEqual(today["groups"], [["key": "2026-10-10", "minutes": 30, "billable_minutes": 30]])
        let friday = try call("summarize", ["start": "2026-10-09", "end": "2026-10-09", "group_by": "day"])
        XCTAssertEqual(friday["groups"], [["key": "2026-10-09", "minutes": 30, "billable_minutes": 30]])
        let instants = try call("summarize", ["start": "2026-10-09T14:15:00Z", "end": "2026-10-09T15:15:00Z", "group_by": "day"])
        XCTAssertEqual(instants["total_minutes"], 30)
    }

    func testFiguresAreRoundedOnceAndTotalsComeFromSeconds() throws {
        let t = now.addingTimeInterval(-3 * 3600)
        let acme = try store.ensureProject("Acme / Phase 2")
        for (i, category) in ["Implementation", "Meetings", "Presales"].enumerated() {
            let start = t + Double(i) * 3600
            // 20 minutes and 20 seconds each: groups round to 20.3, the 61 minute total to 61.0.
            try store.createEntry(NewTimeEntry(start: start, end: start + 20 * 60 + 20, projectID: acme.id,
                                               categoryID: try store.requireCategory(named: category).id,
                                               origin: .manual), now: now)
        }

        let summary = try call("summarize", ["range": "today", "group_by": "category"])
        XCTAssertEqual(summary["groups"], [["key": "Implementation", "minutes": .number(20.3), "billable_minutes": .number(20.3)],
                                           ["key": "Meetings", "minutes": .number(20.3), "billable_minutes": .number(20.3)],
                                           ["key": "Presales", "minutes": .number(20.3), "billable_minutes": 0]])
        XCTAssertEqual(summary["total_minutes"], 61)
        XCTAssertEqual(summary["billable_minutes"], .number(40.7))

        let csv = try call("timesheet", ["range": "today", "format": "csv"])
        XCTAssertEqual(csv.stringValue?.split(separator: "\n").dropFirst().map { $0.split(separator: ",")[4] },
                       ["0.34", "0.34", "0.34"])
    }

    private func keys(_ result: JSONValue) -> [String] {
        guard case .array(let groups)? = result["groups"] else { return [] }
        return groups.compactMap { $0["key"]?.stringValue }
    }

    func testFiltersAndGroupBysWorkOrSayWhyNot() throws {
        let t = TimeRange.parseDate("2026-10-09T09:00:00Z")!
        try store.work(ActivitySample(appName: "Xcode", title: "acme code"),
                       from: t, to: t + 3600)
        try store.work(ActivitySample(appName: "Safari", title: "beta docs"),
                       from: t + 3600, to: t + 5400)
        _ = try call("create_project", ["name": "Phase 2", "client": "Acme"])
        _ = try call("create_project", ["name": "Rollout", "client": "Beta"])
        _ = try call("create_rule", ["project": "Acme / Phase 2", "field": "app_name", "op": "equals", "pattern": "Xcode"])
        _ = try call("create_rule", ["project": "Beta / Rollout", "field": "app_name", "op": "equals", "pattern": "Safari"])

        // Unlogged time honours project and client by the bucket's label.
        let acmeOnly = try call("evidence", ["kind": "unlogged", "client": "Acme"])
        XCTAssertEqual(acmeOnly["groups"], [["key": "Acme / Phase 2", "minutes": 60, "billable_minutes": 60]])
        XCTAssertEqual(try call("evidence", ["kind": "unlogged", "project": "Beta / Rollout"])["total_minutes"], 30)

        // ...and rejects text and sources by name.
        let text = try call("evidence", ["kind": "unlogged", "text": "acme"], expectError: true)
        XCTAssertTrue(text.stringValue?.contains("text") == true, "\(text)")
        let sources = try call("evidence", ["kind": "unlogged", "sources": ["window"]], expectError: true)
        XCTAssertTrue(sources.stringValue?.contains("sources") == true, "\(sources)")

        // Evidence of activities honours text and sources.
        XCTAssertEqual(keys(try call("evidence", ["text": "beta"])), ["Beta / Rollout"])
        XCTAssertEqual(keys(try call("evidence", ["sources": ["agent:codex"]])), [])

        // Time entries have no sources: summarize and timesheet say so.
        for tool in ["summarize", "timesheet"] {
            let error = try call(tool, ["sources": ["window"]], expectError: true)
            XCTAssertTrue(error.stringValue?.contains("sources") == true, "\(tool): \(error)")
        }

        // Group-bys that don't apply to time entries or Unlogged time are errors naming them.
        for groupBy in ["app", "source"] {
            let summary = try call("summarize", ["group_by": .string(groupBy)], expectError: true)
            XCTAssertTrue(summary.stringValue?.contains(groupBy) == true, "\(summary)")
            let unlogged = try call("evidence", ["kind": "unlogged", "group_by": .string(groupBy)], expectError: true)
            XCTAssertTrue(unlogged.stringValue?.contains(groupBy) == true, "\(unlogged)")
        }

        // Entry text matches title and notes, not tags; summarize and the timesheet honour status.
        _ = try call("create_time_entry", ["start": "2026-10-09T09:00:00Z", "end": "2026-10-09T10:00:00Z",
                                           "project": "Acme / Phase 2", "notes": "wrote the integration"])
        _ = try call("create_time_entry", ["start": "2026-10-09T10:00:00Z", "end": "2026-10-09T10:30:00Z",
                                           "project": "Beta / Rollout", "title": "docs", "tags": ["integration"]])
        _ = try call("create_time_entry", ["start": "2026-10-09T11:00:00Z", "end": "2026-10-09T11:15:00Z",
                                           "project": "Beta / Rollout", "title": "draft docs", "status": "draft"])
        let integration = try call("summarize", ["text": "integration"])
        XCTAssertEqual(keys(integration), ["Acme / Phase 2"])
        XCTAssertEqual(integration["total_minutes"], 60)
        XCTAssertEqual(try call("summarize", ["status": "draft"])["total_minutes"], 15)
        XCTAssertEqual(try call("timesheet", ["status": "draft"]),
                       [["date": "2026-10-09", "client": "Beta", "project": "Beta / Rollout",
                         "hours": .number(0.25), "billable_hours": .number(0.25), "notes": ["draft docs"]]])
        guard case .array(let confirmed) = try call("timesheet", ["status": "confirmed", "include_drafts": true]) else {
            return XCTFail("timesheet")
        }
        XCTAssertEqual(confirmed.count, 2)

        // Tool descriptions say what text matches.
        let list = try send(#"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#)
        guard case .array(let tools)? = list["result"]?["tools"] else { return XCTFail("no tools") }
        func textDescription(_ name: String) -> String? {
            tools.first { $0["name"] == .string(name) }?["inputSchema"]?["properties"]?["text"]?["description"]?.stringValue
        }
        for name in ["summarize", "timesheet", "query_time_entries"] {
            XCTAssertEqual(textDescription(name), "Substring match on entry title or notes.", name)
        }
        XCTAssertTrue(textDescription("evidence")?.contains("title, app, URL, path or note") == true)
        XCTAssertTrue(textDescription("evidence")?.contains("not unlogged") == true)
    }
}
