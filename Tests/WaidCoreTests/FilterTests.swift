import Foundation
import XCTest
@testable import WaidCore

/// Filters and group-bys either work or say why not, for Summaries, Evidence and Unlogged time.
final class FilterTests: XCTestCase {
    var store: Store!
    var acme: Project!
    var beta: Project!
    var waid: Project!
    var implementation: WaidCore.Category!
    var meetings: WaidCore.Category!
    let t0 = TimeRange.parseDate("2026-10-09T09:00:00Z")!
    var day: DateInterval { DateInterval(start: t0 - 9 * 3600, duration: 86400) }
    var now: Date { t0 + 8 * 3600 }

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
        acme = try store.ensureProject("Acme / Phase 2")
        beta = try store.ensureProject("Beta / Rollout")
        waid = try store.ensureProject("waid")
        implementation = try store.requireCategory(named: "Implementation")
        meetings = try store.requireCategory(named: "Meetings")
        try store.addRule(projectID: acme.id, field: .appName, op: .equals, pattern: "Xcode")
        try store.addRule(projectID: beta.id, field: .appName, op: .equals, pattern: "Safari")
        try store.addRule(projectID: waid.id, field: .appName, op: .equals, pattern: "Terminal")
        try store.addRule(categoryID: implementation.id, field: .title, op: .contains, pattern: "code")
        try store.addRule(categoryID: meetings.id, field: .title, op: .contains, pattern: "sync")
    }

    private func window(_ app: String, _ title: String, from: Double, minutes: Double) throws {
        try store.insertActivity(start: t0 + from * 60, end: t0 + (from + minutes) * 60, source: Source.window,
                                 sample: ActivitySample(appName: app, title: title))
    }

    @discardableResult
    private func entry(_ from: Double, minutes: Double, _ project: Project?, _ category: WaidCore.Category? = nil,
                       title: String? = nil, notes: String? = nil, tags: [String] = [],
                       status: EntryStatus = .confirmed) throws -> TimeEntry {
        var e = NewTimeEntry(start: t0 + from * 60, end: t0 + (from + minutes) * 60, projectID: project?.id,
                             categoryID: category?.id, title: title, origin: .manual)
        e.notes = notes
        e.tags = tags
        e.status = status
        return try store.createEntry(e, now: now)
    }

    // MARK: Unlogged time

    /// Acme code 60 min, Acme sync 30 min, Beta code 20 min, waid code 40 min.
    private func unloggedDay() throws {
        try window("Xcode", "code review", from: 0, minutes: 60)
        try window("Xcode", "weekly sync", from: 60, minutes: 30)
        try window("Safari", "code search", from: 90, minutes: 20)
        try window("Terminal", "code", from: 110, minutes: 40)
    }

    func testUnloggedTimeFiltersByTheBucketsProject() throws {
        try unloggedDay()
        var f = Store.ActivityFilter()
        f.projectID = acme.id
        let unlogged = try store.unloggedTime(in: .instants(day), groupBy: .project, filter: f, now: now)
        XCTAssertEqual(unlogged.groups.map(\.key), ["Acme / Phase 2"])
        XCTAssertEqual(unlogged.seconds, 90 * 60)
    }

    func testUnloggedTimeFiltersByTheBucketsClient() throws {
        try unloggedDay()
        var f = Store.ActivityFilter()
        f.clientID = beta.clientID
        let unlogged = try store.unloggedTime(in: .instants(day), groupBy: .project, filter: f, now: now)
        XCTAssertEqual(unlogged.groups.map(\.key), ["Beta / Rollout"])
        XCTAssertEqual(unlogged.seconds, 20 * 60)
    }

    func testUnloggedTimeFiltersByTheBucketsCategory() throws {
        try unloggedDay()
        var f = Store.ActivityFilter()
        f.categoryID = implementation.id
        let unlogged = try store.unloggedTime(in: .instants(day), groupBy: .project, filter: f, now: now)
        XCTAssertEqual(unlogged.groups.map(\.key), ["Acme / Phase 2", "waid", "Beta / Rollout"])
        XCTAssertEqual(unlogged.groups.map(\.seconds), [3600.0, 2400, 1200])
    }

    func testUnloggedTimeRejectsTextAndSourcesByName() throws {
        try unloggedDay()
        var text = Store.ActivityFilter()
        text.text = "code"
        XCTAssertThrowsError(try store.unloggedTime(in: .instants(day), groupBy: .project, filter: text, now: now)) {
            XCTAssertTrue("\($0)".contains("text"), "\($0)")
        }
        var sources = Store.ActivityFilter()
        sources.sources = [Source.window]
        XCTAssertThrowsError(try store.unloggedTime(in: .instants(day), groupBy: .project, filter: sources, now: now)) {
            XCTAssertTrue("\($0)".contains("sources"), "\($0)")
        }
    }

    func testUnloggedTimeAndSummariesRejectAppAndSourceGroupings() throws {
        for groupBy in [Store.GroupBy.app, .source] {
            XCTAssertThrowsError(try store.unloggedTime(in: .instants(day), groupBy: groupBy, now: now)) {
                XCTAssertTrue("\($0)".contains(groupBy.rawValue), "\($0)")
            }
            XCTAssertThrowsError(try store.summary(in: .instants(day), groupBy: groupBy, now: now)) {
                XCTAssertTrue("\($0)".contains(groupBy.rawValue), "\($0)")
            }
        }
    }

    // MARK: Summaries

    func testSummaryTextMatchesEntryTitleAndNotesNotTags() throws {
        try entry(0, minutes: 30, acme, title: "Design review")
        try entry(30, minutes: 20, beta, notes: "reviewed the rollout plan")
        try entry(60, minutes: 10, waid, title: "Admin", tags: ["review"])
        var f = Store.EntryFilter()
        f.text = "review"
        let summary = try store.summary(in: .instants(day), groupBy: .project, filter: f, now: now)
        XCTAssertEqual(summary.groups.map(\.key), ["Acme / Phase 2", "Beta / Rollout"])
        XCTAssertEqual(summary.seconds, 50 * 60)
    }

    func testSummaryFiltersByProjectClientAndCategory() throws {
        try entry(0, minutes: 30, acme, implementation)
        try entry(30, minutes: 20, acme, meetings)
        try entry(60, minutes: 10, beta, implementation)
        try entry(70, minutes: 40, waid, implementation)

        var project = Store.EntryFilter()
        project.projectID = acme.id
        XCTAssertEqual(try store.summary(in: .instants(day), groupBy: .category, filter: project, now: now).groups.map(\.key),
                       ["Implementation", "Meetings"])
        var client = Store.EntryFilter()
        client.clientID = beta.clientID
        XCTAssertEqual(try store.summary(in: .instants(day), groupBy: .project, filter: client, now: now).groups.map(\.key),
                       ["Beta / Rollout"])
        var category = Store.EntryFilter()
        category.categoryID = implementation.id
        let byCategory = try store.summary(in: .instants(day), groupBy: .project, filter: category, now: now)
        XCTAssertEqual(byCategory.groups.map(\.key), ["waid", "Acme / Phase 2", "Beta / Rollout"])
        XCTAssertEqual(byCategory.seconds, 80 * 60)
    }

    // MARK: Evidence

    func testEvidenceFiltersByProjectClientCategoryTextAndSources() throws {
        try unloggedDay()
        try store.upsertExternal(source: Source.agent("claude-code"), externalID: "s#0", start: t0, end: t0 + 1800,
                                 title: "agent code", path: "/src/acme")
        func keys(_ configure: (inout Store.ActivityFilter) -> Void) throws -> [String] {
            var f = Store.ActivityFilter()
            configure(&f)
            return try store.evidence(in: .instants(day), groupBy: .project, filter: f, now: now).map(\.key)
        }
        XCTAssertEqual(try keys { $0.projectID = beta.id }, ["Beta / Rollout"])
        XCTAssertEqual(try keys { $0.clientID = acme.clientID }, ["Acme / Phase 2"])
        XCTAssertEqual(try keys { $0.categoryID = meetings.id }, ["Acme / Phase 2"])
        XCTAssertEqual(try keys { $0.text = "search" }, ["Beta / Rollout"])
        XCTAssertEqual(try keys { $0.sources = [Source.agent("claude-code")] }, [TimeAccounting.noProject])
    }

    // MARK: Timesheet

    func testTimesheetHonoursTheStatusFilter() throws {
        try entry(0, minutes: 30, acme, title: "confirmed work")
        try entry(30, minutes: 60, acme, title: "drafted work", status: .draft)

        XCTAssertEqual(try store.timesheet(in: .instants(day), now: now).map(\.notes), [["confirmed work"]],
                       "confirmed only by default")
        XCTAssertEqual(try store.timesheet(in: .instants(day), includeDrafts: true, now: now).map(\.hours), [1.5])
        var drafts = Store.EntryFilter()
        drafts.status = .draft
        XCTAssertEqual(try store.timesheet(in: .instants(day), filter: drafts, now: now).map(\.notes), [["drafted work"]])
        var confirmed = Store.EntryFilter()
        confirmed.status = .confirmed
        XCTAssertEqual(try store.timesheet(in: .instants(day), filter: confirmed, includeDrafts: true, now: now).map(\.hours), [0.5])
    }
}
