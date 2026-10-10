import Foundation
import XCTest
@testable import WaidCore

/// Every report counts time the same way: a Running span ends at now, or at
/// its start if that is later; finished spans count in full, even in the future.
final class DurationTests: XCTestCase {
    var store: Store!
    let t0 = TimeRange.parseDate("2026-10-09T09:00:00Z")!
    var now: Date { t0 + 2 * 3600 }
    var day: DateInterval { DateInterval(start: t0 - 9 * 3600, duration: 86400) }
    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
        store.processZone = TimeZone(identifier: "UTC")!
    }

    func testRunningActivityStartingAfterNowCountsAsZero() throws {
        try store.insertActivity(start: now + 600, end: nil, source: Source.window,
                                 sample: ActivitySample(appName: "Xcode"))
        let listed = try store.activities(in: day)
        XCTAssertEqual(listed.map { $0.duration(now: now) }, [0])
        XCTAssertEqual(try store.evidence(in: .instants(day), groupBy: .app, now: now), [])
    }

    func testRunningSpansCountUpToNow() throws {
        // An open observation isn't Running: it counts up to its last heartbeat.
        let open = try store.insertActivity(start: t0, end: nil, source: Source.window, sample: ActivitySample(appName: "Xcode"))
        try store.setEnd(activityID: open, end: now)
        let project = try store.ensureProject("Acme / Phase 2")
        try store.startTimer(projectID: project.id, now: t0 + 1800)

        XCTAssertEqual(try store.evidence(in: .instants(day), groupBy: .app, now: now).map(\.secondsBySource),
                       [[Source.window: 2.0 * 3600]])
        XCTAssertEqual(try store.summary(in: .instants(day), groupBy: .project, now: now).groups.map(\.seconds), [1.5 * 3600])
        XCTAssertEqual(try store.timesheet(in: .instants(day), now: now).map(\.hours), [1.5])
        XCTAssertEqual(try store.budgetStatus(projectIDs: [project.id], now: now).map(\.usedHours), [1.5])
    }

    func testFinishedEntryLaterTodayCounts() throws {
        let project = try store.ensureProject("Acme / Phase 2")
        try store.createEntry(NewTimeEntry(start: now + 3600, end: now + 2 * 3600, projectID: project.id,
                                           title: "steering meeting", origin: .manual), now: now)

        XCTAssertEqual(try store.summary(in: .instants(day), groupBy: .project, now: now).groups.map(\.seconds), [3600])
        XCTAssertEqual(try store.timesheet(in: .instants(day), now: now).map(\.hours), [1])
        XCTAssertEqual(try store.budgetStatus(projectIDs: [project.id], now: now).map(\.usedHours), [1])
    }

    func testBudgetStatusAgreesWithTimesheet() throws {
        let acme = try store.createProject(name: "Phase 2", clientID: try store.ensureClient(named: "Acme").id, budgetHours: 40)
        let presales = try store.requireCategory(named: "Presales")
        func add(_ start: Date, minutes: Double, category: Category? = nil, draft: Bool = false) throws {
            var e = NewTimeEntry(start: start, end: start + minutes * 60, projectID: acme.id, categoryID: category?.id,
                                 origin: .manual)
            if draft { e.status = .draft }
            try store.createEntry(e, now: now)
        }
        try add(t0 - 3 * 86400, minutes: 50)                       // days ago
        try add(t0 - 3600, minutes: 20, category: presales)         // not billable
        try add(t0 - 7200, minutes: 25, draft: true)
        try add(now + 3600, minutes: 45)                            // later today
        try store.startTimer(projectID: acme.id, now: t0)           // running: 2 h to now

        let budget = try XCTUnwrap(try store.budgetStatus(now: now).first)
        let allTime = DateInterval(start: t0 - 30 * 86400, end: t0 + 30 * 86400)
        let sheet = try store.timesheet(in: .instants(allTime), now: now)
        let withDrafts = try store.timesheet(in: .instants(allTime), includeDrafts: true, now: now)
        func total(_ rows: [Store.TimesheetRow], _ value: (Store.TimesheetRow) -> Double) -> Double { rows.reduce(0) { $0 + value($1) } }

        XCTAssertEqual(budget.usedHours, (50 + 20 + 45 + 120) / 60.0, accuracy: 1e-9)
        XCTAssertEqual(budget.usedHours, total(sheet, \.hours), accuracy: 1e-9)
        XCTAssertEqual(budget.billableHours, total(sheet, \.billableHours), accuracy: 1e-9)
        XCTAssertEqual(budget.billableHours, (50 + 45 + 120) / 60.0, accuracy: 1e-9)
        XCTAssertEqual(budget.draftHours, total(withDrafts, \.hours) - total(sheet, \.hours), accuracy: 1e-9)
        XCTAssertEqual(budget.draftHours, 25 / 60.0, accuracy: 1e-9)
    }

    func testGroupsAddUpToTheTotal() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        let beta = try store.ensureProject("Beta / Rollout")
        let implementation = try store.requireCategory(named: "Implementation")
        let meetings = try store.requireCategory(named: "Meetings")
        // 22:40–01:20 crosses UTC midnight; the rest are odd lengths that don't round to whole minutes.
        try store.createEntry(NewTimeEntry(start: t0 - (10 * 60 + 20) * 60, end: t0 - (7 * 60 + 40) * 60, projectID: acme.id,
                                           categoryID: meetings.id, origin: .manual), now: now)
        try store.createEntry(NewTimeEntry(start: t0, end: t0 + 20, projectID: acme.id,
                                           categoryID: implementation.id, origin: .manual), now: now)
        try store.createEntry(NewTimeEntry(start: t0 + 60, end: t0 + 80, projectID: beta.id, origin: .manual), now: now)
        try store.createEntry(NewTimeEntry(start: t0 + 120, end: t0 + 140, origin: .manual), now: now)
        let range = DateInterval(start: t0 - 86400, end: t0 + 86400)
        let total = 160.0 * 60 + 60

        for groupBy in [Store.GroupBy.project, .client, .category, .day] {
            let summary = try store.summary(in: .instants(range), groupBy: groupBy, now: now)
            XCTAssertEqual(summary.seconds, total, "\(groupBy)")
            XCTAssertEqual(summary.groups.reduce(0) { $0 + $1.seconds }, total, "\(groupBy)")
        }
        XCTAssertEqual(try store.summary(in: .instants(range), groupBy: .day, now: now).groups.map(\.seconds),
                       [80.0 * 60, 80.0 * 60 + 60])
        XCTAssertEqual(try store.timesheet(in: .instants(range), now: now).reduce(0) { $0 + $1.hours }, total / 3600,
                       accuracy: 1e-9)
    }
}
