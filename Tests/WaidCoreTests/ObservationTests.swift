import Foundation
import XCTest
@testable import WaidCore

/// The observation rules the database enforces, driven through the Store API.
final class ObservationTests: XCTestCase {
    var store: Store!
    let t0 = TimeRange.parseDate("2026-10-09T09:00:00Z")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let editor = ActivitySample(appName: "Xcode", title: "main.swift")

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
    }

    func testOverlapWithinAStreamAndSourceIsRejected() throws {
        try store.insertActivity(start: t0, end: t0 + 600, source: Source.window, sample: editor)
        XCTAssertThrowsError(try store.insertActivity(start: t0 + 300, end: t0 + 900, source: Source.window, sample: editor))
        // Touching is fine, and so is overlap with another source.
        try store.insertActivity(start: t0 + 600, end: t0 + 900, source: Source.window, sample: editor)
        try store.insertActivity(start: t0 + 300, end: t0 + 900, source: Source.agent("codex"))
    }

    func testOnlyOneObservationPerStreamAndSourceIsOpen() throws {
        let first = try store.insertActivity(start: t0, end: nil, source: Source.window, sample: editor)
        XCTAssertThrowsError(try store.insertActivity(start: t0 + 60, end: nil, source: Source.window, sample: editor))
        try store.close(activityID: first, end: t0 + 30)
        try store.insertActivity(start: t0 + 60, end: nil, source: Source.window, sample: editor)
    }

    func testAClosedWindowObservationKeepsItsTimeButNotItsOverrides() throws {
        let id = try store.insertActivity(start: t0, end: nil, source: Source.window, sample: editor)
        try store.setEnd(activityID: id, end: t0 + 300)
        try store.close(activityID: id, end: t0 + 600)
        XCTAssertThrowsError(try store.setEnd(activityID: id, end: t0 + 900))
        XCTAssertEqual(try store.activity(id: id)?.end, t0 + 600)

        let project = try store.ensureProject("waid")
        let meetings = try store.requireCategory(named: "Meetings")
        XCTAssertEqual(try store.assign(activityIDs: [id], projectID: project.id, categoryID: meetings.id), 1)
        XCTAssertEqual(try store.setHidden(activityIDs: [id], hidden: true), 1)
        let activity = try XCTUnwrap(try store.activity(id: id))
        XCTAssertEqual(activity.assignedProjectID, project.id)
        XCTAssertEqual(activity.assignedCategoryID, meetings.id)
        XCTAssertTrue(activity.hidden)
    }

    func testAgentSegmentsStayUpsertableAndMayRunInParallel() throws {
        let agent = Source.agent("claude-code")
        let id = try store.upsertExternal(source: agent, externalID: "s#0", start: t0, end: t0 + 600,
                                          title: "fix tests", path: "/src/waid")
        XCTAssertEqual(try store.upsertExternal(source: agent, externalID: "s#0", start: t0, end: t0 + 1200,
                                                title: "fix tests", path: "/src/waid"), id)
        XCTAssertEqual(try store.activity(id: id)?.end, t0 + 1200)

        // Another session in the same source, at the same time.
        let other = try store.upsertExternal(source: agent, externalID: "t#0", start: t0 + 300, end: t0 + 900,
                                             title: "write docs", path: "/src/site")
        XCTAssertNotEqual(other, id)
        XCTAssertEqual(try store.activities(in: DateInterval(start: t0, duration: 3600)).count, 2)
    }

    func testADatabaseFromBeforeObservationsIsRefusedNotMigrated() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Database(path: path).execute("PRAGMA user_version = 4")
        XCTAssertThrowsError(try Store(path: path)) { XCTAssertTrue("\($0)".contains("move it aside"), "\($0)") }

        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: fresh) }
        try Store(path: fresh).insertActivity(start: t0, end: t0 + 60, source: Source.window, sample: editor)
        XCTAssertEqual(try Store(path: fresh).activities(in: DateInterval(start: t0, duration: 60)).count, 1, "reopens")
    }

    func testADatabaseFromANewerWaidIsRefusedAsNewer() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Database(path: path).execute("PRAGMA user_version = 99")
        XCTAssertThrowsError(try Store(path: path)) {
            XCTAssertTrue("\($0)".contains("newer version of waid"), "\($0)")
            XCTAssertFalse("\($0)".contains("before observations"), "\($0)")
        }
    }

    func testANewDatabaseHoldsTheDefaultIdleThreshold() throws {
        XCTAssertEqual(try store.value(forKey: "idle_threshold_seconds"), "180")
    }

    func testObservationsCarryTheirZoneAndLocalDate() throws {
        // 21:00 UTC on the 9th is 06:00 on the 10th in Tokyo.
        let late = TimeRange.parseDate("2026-10-09T21:00:00Z")!
        let window = try store.insertActivity(start: late, end: late + 600, source: Source.window, sample: editor, zone: tokyo)
        let agent = try store.upsertExternal(source: Source.agent("claude-code"), externalID: "s#0", start: late,
                                             end: late + 600, title: "fix tests", path: nil, zone: tokyo)
        for id in [window, agent] {
            let activity = try XCTUnwrap(try store.activity(id: id))
            XCTAssertEqual(activity.zone, "Asia/Tokyo")
            XCTAssertEqual(activity.localDate, "2026-10-10")
        }
    }

    func testTimeEntriesCarryTheProcessZoneAndTheirLocalDates() throws {
        store.processZone = tokyo

        // 23:00 to 01:00 in Tokyo: one entry, two local dates.
        let late = TimeRange.parseDate("2026-10-09T23:00:00+09:00")!
        let crossing = try store.createEntry(NewTimeEntry(start: late, end: late + 7200, origin: .manual), now: late + 7200)
        XCTAssertEqual(crossing.zone, "Asia/Tokyo")
        XCTAssertEqual(crossing.startDate, "2026-10-09")
        XCTAssertEqual(crossing.endDate, "2026-10-10")

        // Ending at midnight leaves no time on the next date.
        let evening = try store.createEntry(NewTimeEntry(start: late - 3600, end: late, origin: .away), now: late + 7200)
        XCTAssertEqual(evening.endDate, "2026-10-09")
        XCTAssertEqual(evening.origin, .away)

        let timer = try store.startTimer(projectID: nil, now: late + 3 * 3600).started
        XCTAssertEqual(timer.startDate, "2026-10-10")
        XCTAssertNil(timer.endDate, "no last date while running")
        let stopped = try XCTUnwrap(try store.stopTimer(now: late + 4 * 3600))
        XCTAssertEqual(stopped.endDate, "2026-10-10")

        var move = TimeEntryChanges()
        move.end = .some(late + 26 * 3600)
        XCTAssertEqual(try store.updateEntry(id: stopped.id, move, now: late + 27 * 3600).endDate, "2026-10-11")
    }
}
