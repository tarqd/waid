import Foundation
import XCTest
@testable import WaidCore

final class RecorderTests: XCTestCase {
    var store: Store!
    let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
    }

    func testSameWindowExtendsSpan() throws {
        let recorder = ActivityRecorder(store: store, maxGap: 15)
        let editor = ActivitySample(bundleID: "com.apple.dt.Xcode", appName: "Xcode", title: "main.swift")
        for i in 0..<4 { try recorder.record(editor, at: t0.addingTimeInterval(Double(i) * 5)) }
        let spans = try store.activities(in: DateInterval(start: t0, duration: 3600))
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].duration(), 15)
    }

    func testTitleChangeAndGapStartNewSpans() throws {
        let recorder = ActivityRecorder(store: store, maxGap: 15)
        try recorder.record(ActivitySample(appName: "Xcode", title: "a.swift"), at: t0)
        try recorder.record(ActivitySample(appName: "Xcode", title: "b.swift"), at: t0.addingTimeInterval(5))
        // Machine slept for an hour.
        try recorder.record(ActivitySample(appName: "Xcode", title: "b.swift"), at: t0.addingTimeInterval(3605))
        let spans = try store.activities(in: DateInterval(start: t0, duration: 7200))
        XCTAssertEqual(spans.map(\.title), ["a.swift", "b.swift", "b.swift"])
        XCTAssertEqual(spans[0].duration(), 5, "closed at the switch, not the last sample")
        XCTAssertEqual(spans[1].duration(), 0, "not extended across the sleep gap")
    }

    func testIdleTrimsTail() throws {
        let recorder = ActivityRecorder(store: store, maxGap: 15, idleThreshold: 60)
        let s = ActivitySample(appName: "Safari", title: "Docs")
        var idle = s
        for i in 0...20 {
            idle.idleSeconds = Double(max(0, i * 5 - 30))  // last input at t0+30
            try recorder.record(idle, at: t0.addingTimeInterval(Double(i) * 5))
        }
        let spans = try store.activities(in: DateInterval(start: t0, duration: 3600))
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].duration(), 30, accuracy: 0.001)
    }
}

final class RuleTests: XCTestCase {
    func testRulesApplyRetroactivelyByPriorityAndAssignmentWins() throws {
        let store = try Store(path: ":memory:")
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        let a = try store.insertActivity(start: t0, end: t0 + 600, source: Source.window,
                                         sample: ActivitySample(appName: "Safari", url: "https://github.com/tarqd/waid"))
        let b = try store.insertActivity(start: t0 + 600, end: t0 + 900, source: Source.window,
                                         sample: ActivitySample(appName: "Safari", url: "https://news.ycombinator.com"))
        let waid = try store.ensureProject("waid")
        let browsing = try store.ensureProject("Browsing")
        try store.addRule(projectID: browsing.id, field: .appName, op: .equals, pattern: "safari")
        try store.addRule(projectID: waid.id, field: .url, op: .regex, pattern: "github\\.com/tarqd/waid", priority: 10)

        let range = DateInterval(start: t0, duration: 3600)
        var spans = try store.activities(in: range)
        XCTAssertEqual(spans.map(\.project), ["waid", "Browsing"])

        try store.assign(activityIDs: [b], projectID: waid.id)
        spans = try store.activities(in: range)
        XCTAssertEqual(spans.map(\.project), ["waid", "waid"])

        var filter = Store.ActivityFilter()
        filter.uncategorizedOnly = true
        try store.assign(activityIDs: [a], projectID: .some(nil))
        XCTAssertTrue(try store.activities(in: range, filter: filter).isEmpty, "rules still categorize a")
    }

    func testInvalidRegexRejected() throws {
        let store = try Store(path: ":memory:")
        let p = try store.ensureProject("x")
        XCTAssertThrowsError(try store.addRule(projectID: p.id, field: .title, op: .regex, pattern: "("))
    }
}

final class EvidenceTests: XCTestCase {
    func testDayGroupingSplitsAtMidnightAndClipsToRange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let store = try Store(path: ":memory:")
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9))!
        try store.insertActivity(start: midnight - 1800, end: midnight + 3600, source: Source.window,
                                 sample: ActivitySample(appName: "Terminal"))
        try store.insertActivity(start: midnight, end: midnight + 600, source: Source.agent("claude-code"))

        let rows = try store.evidence(in: DateInterval(start: midnight - 86400, end: midnight + 86400),
                                     groupBy: .day, calendar: calendar)
        XCTAssertEqual(rows.map(\.key), ["2026-10-08", "2026-10-09"])
        XCTAssertEqual(rows[0].secondsBySource, ["window": 1800])
        XCTAssertEqual(rows[1].secondsBySource, ["window": 3600, "agent:claude-code": 600])

        let clipped = try store.evidence(in: DateInterval(start: midnight, duration: 1200), groupBy: .source)
        XCTAssertEqual(clipped.first { $0.key == "window" }?.secondsBySource["window"], 1200)
    }
}

final class DaySplitTests: XCTestCase {
    var calendar = Calendar(identifier: .gregorian)
    var store: Store!
    var midnight: Date!
    var range: DateInterval { DateInterval(start: midnight - 86400, end: midnight + 86400) }
    var now: Date { midnight + 6 * 3600 }

    override func setUpWithError() throws {
        calendar.timeZone = TimeZone(identifier: "UTC")!
        store = try Store(path: ":memory:")
        midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9))!
    }

    func testSummaryAndTimesheetSplitEntriesAtMidnight() throws {
        let waid = try store.ensureProject("waid")
        try store.createEntry(NewTimeEntry(start: midnight - 1800, end: midnight + 3600, projectID: waid.id,
                                           title: "late night", origin: .manual), now: now)

        let days = try store.summary(in: range, groupBy: .day, calendar: calendar, now: now)
        XCTAssertEqual(days.groups.map(\.key), ["2026-10-08", "2026-10-09"])
        XCTAssertEqual(days.groups.map(\.seconds), [1800, 3600])
        XCTAssertEqual(days.seconds, 5400)

        let rows = try store.timesheet(in: range, calendar: calendar, now: now)
        XCTAssertEqual(rows.map(\.date), ["2026-10-08", "2026-10-09"])
        XCTAssertEqual(rows.map(\.hours), [0.5, 1])
        XCTAssertEqual(rows.map(\.notes), [["late night"], ["late night"]])
    }

    func testUnloggedSplitsAtMidnightAndGroupsByClient() throws {
        let acme = try store.createProject(name: "Phase 2", clientID: try store.ensureClient(named: "Acme").id)
        try store.addRule(projectID: acme.id, field: .appName, op: .equals, pattern: "Xcode")
        try store.insertActivity(start: midnight - 1800, end: midnight + 3600, source: Source.window,
                                 sample: ActivitySample(appName: "Xcode", title: "acme"))

        let days = try store.unloggedTime(in: range, groupBy: .day, calendar: calendar, now: now)
        XCTAssertEqual(days.groups.map(\.key), ["2026-10-08", "2026-10-09"])
        XCTAssertEqual(days.groups.map(\.seconds), [1800, 3600])
        XCTAssertEqual(days.seconds, 5400)

        let clients = try store.unloggedTime(in: range, groupBy: .client, calendar: calendar, now: now)
        XCTAssertEqual(clients.groups.map(\.key), ["Acme"])
        XCTAssertEqual(clients.groups.map(\.seconds), [5400])
        XCTAssertEqual(try store.unloggedTime(in: range, groupBy: .project, now: now).groups.map(\.key), ["Acme / Phase 2"])
    }
}

final class TimeRangeTests: XCTestCase {
    func testResolve() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = TimeRange.parseDate("2026-10-09T15:00:00-04:00")!
        let oct9 = LocalDate(year: 2026, month: 10, day: 9)
        XCTAssertEqual(try TimeRange.resolve(range: "today", start: nil, end: nil, now: now, calendar: calendar),
                       .localDates(oct9...oct9))
        XCTAssertEqual(try TimeRange.resolve(range: nil, start: nil, end: nil, now: now, calendar: calendar),
                       .localDates(oct9...oct9))
        XCTAssertEqual(try TimeRange.resolve(range: "this_month", start: nil, end: nil, now: now, calendar: calendar),
                       .localDates(LocalDate("2026-10-01")!...LocalDate("2026-10-31")!))

        XCTAssertEqual(try TimeRange.resolve(range: nil, start: "2026-10-01", end: "2026-10-02", now: now, calendar: calendar),
                       .localDates(LocalDate("2026-10-01")!...LocalDate("2026-10-02")!), "bare end date is inclusive")

        XCTAssertEqual(
            try TimeRange.resolve(range: nil, start: "2026-10-01T09:00:00+09:00", end: "2026-10-01T17:00:00Z", now: now, calendar: calendar),
            .instants(DateInterval(start: TimeRange.parseDate("2026-10-01T00:00:00Z")!, end: TimeRange.parseDate("2026-10-01T17:00:00Z")!)),
            "timestamps with an offset are instants")

        XCTAssertThrowsError(try TimeRange.resolve(range: "fortnight", start: nil, end: nil))
        XCTAssertThrowsError(try TimeRange.resolve(range: nil, start: "2026-10-02", end: "2026-10-01T00:00:00Z"))
    }
}

final class ClaudeCodeIngestorTests: XCTestCase {
    let transcript = """
        {"type":"summary","summary":"Build time tracker MCP","leafUuid":"x"}
        {"type":"user","isMeta":true,"sessionId":"s1","cwd":"/Users/t/waid","timestamp":"2026-10-09T10:00:00.000Z","message":{"role":"user","content":"<command-name>/clear</command-name>"}}
        {"type":"user","sessionId":"s1","cwd":"/Users/t/waid","gitBranch":"main","timestamp":"2026-10-09T10:00:05.000Z","message":{"role":"user","content":"build an MCP server"}}
        {"type":"assistant","sessionId":"s1","cwd":"/Users/t/waid","timestamp":"2026-10-09T10:12:00.500Z","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}
        not json
        {"type":"user","sessionId":"s1","cwd":"/Users/t/waid","timestamp":"2026-10-09T14:00:00Z","message":{"role":"user","content":[{"type":"text","text":"continue"}]}}
        {"type":"assistant","sessionId":"s1","cwd":"/Users/t/waid","timestamp":"2026-10-09T14:05:00Z","message":{"role":"assistant","content":"done"}}
        """

    func testSegmentsSplitOnGaps() {
        let segments = ClaudeCodeIngestor.segments(fromTranscript: Data(transcript.utf8), splitGap: 900)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, TimeRange.parseDate("2026-10-09T10:00:00Z"))
        XCTAssertEqual(segments[0].end.timeIntervalSince(segments[0].start), 720.5, accuracy: 0.01)
        XCTAssertEqual(segments[1].end.timeIntervalSince(segments[1].start), 300)
        XCTAssertEqual(segments[0].title, "Build time tracker MCP")
        XCTAssertEqual(segments[0].cwd, "/Users/t/waid")
        XCTAssertEqual(segments[0].gitBranch, "main")
    }

    func testIngestIsIdempotentAndKeepsAssignments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectDir = dir.appendingPathComponent("-Users-t-waid")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(transcript.utf8).write(to: projectDir.appendingPathComponent("s1.jsonl"))

        let store = try Store(path: ":memory:")
        let ingestor = ClaudeCodeIngestor(root: dir)
        XCTAssertEqual(try ingestor.ingest(into: store).segmentsUpserted, 2)
        let range = DateInterval(start: TimeRange.parseDate("2026-10-09T00:00:00Z")!, duration: 86400)
        let first = try store.activities(in: range)
        XCTAssertEqual(first.count, 2)

        let p = try store.ensureProject("waid")
        try store.assign(activityIDs: [first[0].id], projectID: p.id)
        try ingestor.ingest(into: store, full: true)
        let second = try store.activities(in: range)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second[0].project, "waid")
        XCTAssertEqual(second[0].source, "agent:claude-code")
    }
}
