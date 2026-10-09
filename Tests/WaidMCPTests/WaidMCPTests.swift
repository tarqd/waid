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

        let summary = try call("summarize", ["range": "today"])
        guard case .array(let rows)? = summary["groups"] else { return XCTFail("\(summary)") }
        XCTAssertEqual(rows.first?["key"], "waid")
        XCTAssertEqual(rows.first?["minutes_by_source"]?["window"], 20)
        XCTAssertEqual(rows.last?["key"], "(uncategorized)")

        _ = try call("create_rule", ["project": "nope", "field": "url", "op": "contains", "pattern": "x",
                                     "create_project": false], expectError: true)
        _ = try call("summarize", ["range": "fortnight"], expectError: true)
    }

    func testTimersAndAgentWork() throws {
        let started = try call("start_timer", ["project": "Writing", "note": "blog"])
        XCTAssertEqual(started["project"], "Writing")
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
}
