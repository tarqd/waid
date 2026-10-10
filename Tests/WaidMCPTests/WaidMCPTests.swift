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
        try store.insertActivity(start: t, end: t + 1200, source: Source.window,
                                 sample: ActivitySample(bundleID: "com.apple.Safari", appName: "Safari",
                                                        title: "waid PR", url: "https://github.com/tarqd/waid/pull/2"))
        try store.insertActivity(start: t + 1200, end: t + 1800, source: Source.window,
                                 sample: ActivitySample(bundleID: "com.apple.Terminal", appName: "Terminal", title: "zsh"))

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

    func testSuggestEditConfirmFlowAttributesAgent() throws {
        _ = try send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"Claude Code","version":"2"}}}"#)
        let t = TimeRange.parseDate("2026-10-09T09:00:00Z")!
        try store.insertActivity(start: t, end: t + 3600, source: Source.window,
                                 sample: ActivitySample(appName: "Xcode", title: "Store.swift", path: "/src/waid/Store.swift"))
        _ = try call("create_rule", ["project": "waid", "field": "path", "op": "prefix", "pattern": "/src/waid"])

        let unlogged = try call("evidence", ["range": "today", "kind": "unlogged"])
        XCTAssertEqual(unlogged["kind"], "unlogged")
        XCTAssertEqual(unlogged["groups"], [["key": "waid", "minutes": 60]])
        XCTAssertEqual(unlogged["total_minutes"], 60)
        XCTAssertEqual(try call("get_status")["unlogged_today_minutes"], 60)

        let suggested = try call("suggest_time_entries", ["range": "today"])
        guard case .array(let drafts) = suggested, drafts.count == 1, let draft = drafts.first?["entry"] else {
            return XCTFail("\(suggested)")
        }
        XCTAssertEqual(draft["status"], "draft")
        XCTAssertEqual(draft["author"], "agent:claude-code")
        XCTAssertEqual(draft["title"], "Store.swift")
        XCTAssertEqual(drafts.first?["evidence"], [["label": "Store.swift", "minutes": 60]])
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
}
