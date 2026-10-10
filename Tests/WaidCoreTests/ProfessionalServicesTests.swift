import Foundation
import XCTest
@testable import WaidCore

final class ProfessionalServicesTests: XCTestCase {
    var store: Store!
    let t0 = TimeRange.parseDate("2026-10-09T09:00:00Z")!
    var day: DateInterval { DateInterval(start: t0 - 9 * 3600, duration: 86400) }
    var now: Date { t0 + 8 * 3600 }

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
    }

    func testProjectReferences() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        XCTAssertEqual(acme.client, "Acme")
        XCTAssertEqual(acme.path, "Acme / Phase 2")
        XCTAssertTrue(acme.billable, "engagements default to billable")

        let internalProject = try store.ensureProject("waid")
        XCTAssertNil(internalProject.client)
        XCTAssertFalse(internalProject.billable, "internal projects default to non-billable")

        // Same name under different clients is fine; a plain name is then ambiguous.
        try store.ensureProject("Beta / Phase 2")
        XCTAssertThrowsError(try store.findProject("Phase 2")) { XCTAssertTrue("\($0)".contains("ambiguous")) }
        XCTAssertEqual(try store.findProject("acme / phase 2")?.id, acme.id)
        XCTAssertThrowsError(try store.createProject(name: "Phase 2", clientID: acme.clientID))

        // An internal project wins a plain-name lookup.
        try store.createProject(name: "Phase 2")
        XCTAssertNil(try store.findProject("Phase 2")?.clientID)
        XCTAssertThrowsError(try store.requireCategory(named: "Nope")) { XCTAssertTrue("\($0)".contains("Presales")) }
    }

    func testBillableDerivesFromProjectAndCategory() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        let internalProject = try store.ensureProject("waid")
        let presales = try store.requireCategory(named: "Presales")
        let implementation = try store.requireCategory(named: "Implementation")

        func entry(_ hour: Double, _ project: Project, _ category: Category?, billable: Bool? = nil) throws -> TimeEntry {
            var e = NewTimeEntry(start: t0 + hour * 3600, end: t0 + (hour + 1) * 3600, projectID: project.id,
                                 categoryID: category?.id, origin: .manual)
            e.billable = billable
            return try store.createEntry(e, now: now)
        }
        XCTAssertTrue(try entry(0, acme, implementation).billable)
        XCTAssertTrue(try entry(1, acme, nil).billable)
        XCTAssertFalse(try entry(2, acme, presales).billable, "presales is never billable")
        XCTAssertFalse(try entry(3, internalProject, implementation).billable, "internal work isn't billable")
        let forced = try entry(4, internalProject, nil, billable: true)
        XCTAssertTrue(forced.billable)

        // Recategorizing re-derives billable unless it's passed explicitly.
        var change = TimeEntryChanges()
        change.categoryID = .some(presales.id)
        XCTAssertFalse(try store.updateEntry(id: forced.id, change, now: now).billable)
    }

    func testProjectAndCategoryRulesCombineAndDomainsFindClients() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        try store.ensureClient(named: "Acme", addingDomains: ["https://www.ACME.com/", "acme.atlassian.net"])
        XCTAssertEqual(try store.client(named: "acme")?.domains, ["acme.com", "acme.atlassian.net"])
        XCTAssertThrowsError(try store.ensureClient(named: "Acme", addingDomains: ["not a domain"]))
        let meetings = try store.requireCategory(named: "Meetings")
        try store.addRule(categoryID: meetings.id, field: .appName, op: .equals, pattern: "zoom.us")
        try store.addRule(projectID: acme.id, field: .title, op: .contains, pattern: "acme")
        XCTAssertThrowsError(try store.addRule(field: .title, op: .contains, pattern: "x"))

        try store.work(ActivitySample(appName: "zoom.us", title: "Acme weekly sync"), from: t0, to: t0 + 1800)
        try store.work(ActivitySample(appName: "Safari", title: "PROJ-12", url: "https://eu.acme.atlassian.net/browse/PROJ-12"),
                       from: t0 + 1800, to: t0 + 2400)

        let spans = try store.activities(in: day)
        XCTAssertEqual(spans[0].project, "Acme / Phase 2")
        XCTAssertEqual(spans[0].category, "Meetings")
        XCTAssertEqual(spans[0].client, "Acme")
        XCTAssertNil(spans[1].project)
        XCTAssertEqual(spans[1].client, "Acme", "matched by domain without a project")

        let byClient = try store.evidence(in: .instants(day), groupBy: .client)
        XCTAssertEqual(byClient.map(\.key), ["Acme"])
        let byCategory = try store.evidence(in: .instants(day), groupBy: .category)
        XCTAssertEqual(Set(byCategory.map(\.key)), ["Meetings", TimeAccounting.noCategory])
    }

    func testSuggestionsSplitByCategory() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        let meetings = try store.requireCategory(named: "Meetings")
        let implementation = try store.requireCategory(named: "Implementation")
        try store.addRule(projectID: acme.id, field: .title, op: .contains, pattern: "acme")
        try store.addRule(categoryID: meetings.id, field: .appName, op: .equals, pattern: "zoom.us")
        try store.addRule(categoryID: implementation.id, field: .appName, op: .equals, pattern: "Xcode")
        try store.work(ActivitySample(appName: "zoom.us", title: "Acme kickoff"), from: t0, to: t0 + 1800)
        try store.work(ActivitySample(appName: "Xcode", title: "acme-integration"), from: t0 + 1800, to: t0 + 5400)

        let drafts = try store.suggestEntries(in: day, now: now).map(\.entry)
        XCTAssertEqual(drafts.map(\.category), ["Meetings", "Implementation"])
        XCTAssertEqual(drafts.map { $0.duration() / 60 }, [30, 60])
        XCTAssertEqual(drafts.map(\.billable), [true, true])
        XCTAssertEqual(drafts.first?.client, "Acme")

        let unlogged = try store.unloggedTime(in: .instants(day), groupBy: .category, now: now)
        XCTAssertEqual(unlogged.groups.map(\.key), ["Implementation", "Meetings"])
        XCTAssertEqual(unlogged.seconds, 90 * 60, "matches the suggested drafts")
    }

    func testUnloggedTimeIsBillableOnlyForBillableProjectsAndCategories() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        let internalProject = try store.ensureProject("waid")
        let presales = try store.requireCategory(named: "Presales")
        let implementation = try store.requireCategory(named: "Implementation")
        try store.addRule(projectID: acme.id, field: .title, op: .contains, pattern: "acme")
        try store.addRule(projectID: internalProject.id, field: .title, op: .contains, pattern: "waid")
        try store.addRule(categoryID: presales.id, field: .appName, op: .equals, pattern: "Keynote")
        try store.addRule(categoryID: implementation.id, field: .appName, op: .equals, pattern: "Xcode")
        try store.work(ActivitySample(appName: "Xcode", title: "acme-integration"), from: t0, to: t0 + 3600)
        try store.work(ActivitySample(appName: "Keynote", title: "Acme pitch"), from: t0 + 3600, to: t0 + 5400)
        try store.work(ActivitySample(appName: "Xcode", title: "waid"), from: t0 + 5400, to: t0 + 7200)

        let byCategory = try store.unloggedTime(in: .instants(day), groupBy: .category, now: now)
        XCTAssertEqual(byCategory.groups, [
            Store.TimeGroup(key: "Implementation", seconds: 90 * 60, billableSeconds: 60 * 60),
            Store.TimeGroup(key: "Presales", seconds: 30 * 60, billableSeconds: 0),
        ])
        let byProject = try store.unloggedTime(in: .instants(day), groupBy: .project, now: now)
        XCTAssertEqual(byProject.groups, [
            Store.TimeGroup(key: "Acme / Phase 2", seconds: 90 * 60, billableSeconds: 60 * 60),
            Store.TimeGroup(key: "waid", seconds: 30 * 60, billableSeconds: 0),
        ])
        XCTAssertEqual(byProject.seconds, 2 * 3600)
        XCTAssertEqual(byProject.billableSeconds, 3600)
    }

    func testBudgetsAndTimesheet() throws {
        let acme = try store.createProject(name: "Phase 2", clientID: try store.ensureClient(named: "Acme").id, budgetHours: 10)
        let prospect = try store.createProject(name: "Opportunity", clientID: try store.ensureClient(named: "Beta").id,
                                               status: .prospect)
        let presales = try store.requireCategory(named: "Presales")
        let implementation = try store.requireCategory(named: "Implementation")
        func add(_ hour: Double, _ hours: Double, _ project: Project, _ category: Category, _ title: String, draft: Bool = false) throws {
            var e = NewTimeEntry(start: t0 + hour * 3600, end: t0 + (hour + hours) * 3600, projectID: project.id,
                                 categoryID: category.id, title: title, origin: .manual)
            if draft { e.status = .draft }
            try store.createEntry(e, now: now)
        }
        try add(0, 2, acme, implementation, "SSO config")
        try add(2, 1, acme, implementation, "data migration, \"phase 1\"")
        try add(3, 1, prospect, presales, "demo")
        try add(4, 1.5, acme, implementation, "unconfirmed", draft: true)

        let budgets = try store.budgetStatus(now: now)
        XCTAssertEqual(budgets.map(\.project), ["Acme / Phase 2"], "only projects with budgets by default")
        XCTAssertEqual(budgets[0].usedHours, 3, accuracy: 0.001)
        XCTAssertEqual(budgets[0].draftHours, 1.5, accuracy: 0.001)
        XCTAssertEqual(budgets[0].remainingHours ?? 0, 7, accuracy: 0.001)
        XCTAssertEqual(budgets[0].burn ?? 0, 0.3, accuracy: 0.001)

        let summary = try store.summary(in: .instants(day), groupBy: .category, now: now)
        XCTAssertEqual(summary.groups.map(\.key), ["Implementation", "Presales"])
        XCTAssertEqual(summary.groups.map(\.billableSeconds), [3.0 * 3600, 0])
        XCTAssertEqual(summary.seconds, 4 * 3600, "drafts excluded by default")
        XCTAssertEqual(summary.billableSeconds, 3 * 3600)
        XCTAssertEqual(summary.utilization, 0.75)

        let withDrafts = try store.summary(in: .instants(day), groupBy: .category, includeDrafts: true, now: now)
        XCTAssertEqual(withDrafts.seconds, 5.5 * 3600)
        XCTAssertEqual(withDrafts.utilization ?? 0, 4.5 / 5.5, accuracy: 0.0001)
        XCTAssertNil(try store.summary(in: .instants(DateInterval(start: t0 - 86400, duration: 3600)), groupBy: .project, now: now).utilization,
                     "no time, no utilization")

        let rows = try store.timesheet(in: .instants(day), now: now)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].hours, 3, accuracy: 0.001)
        XCTAssertEqual(rows[0].notes, ["SSO config", "data migration, \"phase 1\""])
        XCTAssertEqual(Store.csv(rows), [
            "date,client,project,category,hours,billable_hours,notes",
            #"2026-10-09,Acme,Phase 2,Implementation,3.00,3.00,"SSO config; data migration, ""phase 1""""#,
            "2026-10-09,Beta,Opportunity,Presales,1.00,0.00,demo",
        ].joined(separator: "\n") + "\n")

        var onlyBeta = Store.EntryFilter()
        onlyBeta.clientID = try store.client(named: "Beta")?.id
        XCTAssertEqual(try store.timesheet(in: .instants(day), filter: onlyBeta, now: now).map(\.project), ["Beta / Opportunity"])
    }
}
