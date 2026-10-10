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
}
