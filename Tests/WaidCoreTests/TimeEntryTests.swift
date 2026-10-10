import Foundation
import XCTest
@testable import WaidCore

final class TimeEntryTests: XCTestCase {
    var store: Store!
    let t0 = TimeRange.parseDate("2026-10-09T09:00:00Z")!

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
    }

    func testEntriesCannotOverlap() throws {
        let a = try store.createEntry(NewTimeEntry(start: t0, end: t0 + 3600, origin: .manual), now: t0 + 7200)
        XCTAssertThrowsError(try store.createEntry(NewTimeEntry(start: t0 + 1800, end: t0 + 5400, origin: .manual), now: t0 + 7200)) {
            XCTAssertTrue("\($0)".contains("#\(a.id)"), "names the conflicting entry: \($0)")
        }
        // Touching is fine.
        let b = try store.createEntry(NewTimeEntry(start: t0 + 3600, end: t0 + 5400, origin: .manual), now: t0 + 7200)

        var grow = TimeEntryChanges()
        grow.end = .some(t0 + 4000)
        XCTAssertThrowsError(try store.updateEntry(id: a.id, grow, now: t0 + 7200))
        var move = TimeEntryChanges()
        move.start = t0 - 600
        XCTAssertEqual(try store.updateEntry(id: a.id, move, now: t0 + 7200).duration(), 4200, "updating itself isn't an overlap")

        XCTAssertThrowsError(try store.createEntry(NewTimeEntry(start: t0, end: t0, origin: .manual)))
        try store.deleteEntry(id: b.id)
        XCTAssertNil(try store.timeEntry(id: b.id))
    }

    func testTimers() throws {
        let p = try store.ensureProject("waid")
        let first = try store.startTimer(projectID: p.id, title: "code", now: t0)
        XCTAssertNil(first.stopped)
        XCTAssertEqual(try store.runningEntry()?.id, first.started.id)
        XCTAssertEqual(first.started.duration(now: t0 + 600), 600)

        // A finished entry can't be created over the running timer.
        XCTAssertThrowsError(try store.createEntry(NewTimeEntry(start: t0 + 60, end: t0 + 120, origin: .manual), now: t0 + 600))

        let second = try store.startTimer(projectID: nil, now: t0 + 900)
        XCTAssertEqual(second.stopped?.end, t0 + 900)
        XCTAssertEqual(try store.stopTimer(now: t0 + 1000)?.id, second.started.id)
        XCTAssertNil(try store.stopTimer(now: t0 + 1100))
    }
}

final class SuggesterTests: XCTestCase {
    var store: Store!
    var waid: Project!
    var chat: Project!
    let t0 = TimeRange.parseDate("2026-10-09T09:00:00Z")!
    var day: DateInterval { DateInterval(start: t0 - 9 * 3600, duration: 86400) }
    var now: Date { t0 + 8 * 3600 }

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
        waid = try store.ensureProject("waid")
        chat = try store.ensureProject("Chat")
        try store.addRule(projectID: waid.id, field: .appName, op: .equals, pattern: "Xcode")
        try store.addRule(projectID: chat.id, field: .appName, op: .equals, pattern: "Slack")
    }

    private func window(_ app: String, _ title: String, from: Double, minutes: Double) throws {
        try store.insertActivity(start: t0 + from * 60, end: t0 + (from + minutes) * 60, source: Source.window,
                                 sample: ActivitySample(appName: app, title: title))
    }

    func testMergesAcrossInterruptionsAndDropsShortBlocks() throws {
        try window("Xcode", "Store.swift", from: 0, minutes: 20)
        try window("Slack", "#general", from: 20, minutes: 2)       // absorbed interruption
        try window("Xcode", "Tests.swift", from: 22, minutes: 18)
        try window("Finder", "Downloads", from: 40, minutes: 10)     // uncategorized
        try window("Slack", "#team", from: 50, minutes: 5)           // too short alone
        try window("Xcode", "main.swift", from: 90, minutes: 15)     // separate block after a long gap

        let drafts = try store.suggestEntries(in: day, now: now)
        XCTAssertEqual(drafts.map { $0.entry.project }, ["waid", "waid"])
        XCTAssertEqual(drafts[0].entry.start, t0)
        XCTAssertEqual(drafts[0].entry.duration(), 40 * 60)
        XCTAssertEqual(drafts[0].entry.title, "Store.swift · Tests.swift")
        XCTAssertEqual(drafts[0].entry.status, .draft)
        XCTAssertEqual(drafts[1].entry.duration(), 15 * 60)

        // Re-running replaces suggestions rather than duplicating them.
        XCTAssertEqual(try store.suggestEntries(in: day, now: now).count, 2)
        XCTAssertEqual(try store.timeEntries(in: day).count, 2)
    }

    func testSkipsTimeAlreadyLoggedAndAgentsByDefault() throws {
        try window("Xcode", "Store.swift", from: 0, minutes: 60)
        try store.createEntry(NewTimeEntry(start: t0 + 20 * 60, end: t0 + 30 * 60, origin: .manual), now: now)
        try store.upsertExternal(source: Source.agent("claude-code"), externalID: "s#0", start: t0 + 120 * 60,
                                 end: t0 + 180 * 60, title: "agent work", path: "/src/waid")
        try store.addRule(projectID: waid.id, field: .path, op: .prefix, pattern: "/src/waid")

        var drafts = try store.suggestEntries(in: day, now: now)
        XCTAssertEqual(drafts.map { $0.entry.duration() / 60 }, [20, 30], "split around the logged entry, agent ignored")

        var withAgents = EntrySuggester()
        withAgents.includeAgents = true
        drafts = try store.suggestEntries(in: day, using: withAgents, now: now)
        XCTAssertEqual(drafts.map { $0.entry.duration() / 60 }, [20, 30, 60])
        XCTAssertEqual(drafts.last?.entry.title, "agent work")
    }

    func testUnloggedCountsOnlyUncoveredCategorizedTime() throws {
        try window("Xcode", "Store.swift", from: 0, minutes: 60)
        try window("Finder", "Downloads", from: 60, minutes: 30)
        var draft = NewTimeEntry(start: t0 + 40 * 60, end: t0 + 50 * 60, origin: .manual)
        draft.status = .draft
        try store.createEntry(draft, now: now)  // drafts don't count as logged
        try store.createEntry(NewTimeEntry(start: t0, end: t0 + 15 * 60, origin: .manual), now: now)

        let unlogged = try store.unloggedTime(in: .instants(day), groupBy: .project, now: now)
        XCTAssertEqual(unlogged.groups.map(\.key), ["waid"])
        XCTAssertEqual(unlogged.seconds, 45 * 60)
    }
}
