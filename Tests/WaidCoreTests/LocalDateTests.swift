import Foundation
import XCTest
@testable import WaidCore

/// A span's day is its Local date: the date where it happened, stored on the
/// row in its own zone (GLOSSARY.md, ADR-0002), not the zone the report runs in.
final class LocalDateTests: XCTestCase {
    var store: Store!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let newYork = TimeZone(identifier: "America/New_York")!
    /// Monday 2026-10-05 00:00 in Tokyo.
    let mondayTokyo = TimeRange.parseDate("2026-10-05T00:00:00+09:00")!
    /// Saturday after the trip, back in New York.
    let now = TimeRange.parseDate("2026-10-10T12:00:00-04:00")!
    var week: DateInterval { DateInterval(start: mondayTokyo - 86400, end: now) }
    /// The machine's calendar when the report runs: New York.
    var newYorkCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        return calendar
    }

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
        store.processZone = newYork
    }

    private func entry(_ start: String, _ end: String, project: Project) throws {
        try store.createEntry(NewTimeEntry(start: TimeRange.parseDate(start)!, end: TimeRange.parseDate(end)!,
                                           projectID: project.id, origin: .manual), now: now)
    }

    private func observe(_ start: String, _ end: String, in zone: TimeZone, project: Project? = nil) throws {
        try store.insertActivity(start: TimeRange.parseDate(start)!, end: TimeRange.parseDate(end)!, source: Source.window,
                                 sample: ActivitySample(appName: "Xcode"), projectID: project?.id, zone: zone)
    }

    func testATokyoWeekIsReportedAsTokyoDatesFromNewYork() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        // Tuesday morning and Thursday evening in Tokyo: both straddle a New York midnight.
        try observe("2026-10-06T08:00:00+09:00", "2026-10-06T10:00:00+09:00", in: tokyo, project: acme)
        try observe("2026-10-08T12:00:00+09:00", "2026-10-08T15:00:00+09:00", in: tokyo, project: acme)
        // Logged with no zone of their own: they take Tokyo from the observations.
        try entry("2026-10-06T08:00:00+09:00", "2026-10-06T10:00:00+09:00", project: acme)
        try entry("2026-10-08T12:00:00+09:00", "2026-10-08T15:00:00+09:00", project: acme)
        // Home again.
        try observe("2026-10-09T18:00:00-04:00", "2026-10-09T18:30:00-04:00", in: newYork)

        let thisWeek = try TimeRange.resolve(range: "this_week", start: nil, end: nil, now: now, calendar: newYorkCalendar)
        for range in [thisWeek, .instants(week)] {
            let timesheet = try store.timesheet(in: range, now: now)
            XCTAssertEqual(timesheet.map(\.date), ["2026-10-06", "2026-10-08"], "\(range)")
            XCTAssertEqual(timesheet.map(\.hours), [2, 3], "\(range)")

            let byDay = try store.summary(in: range, groupBy: .day, now: now).groups
            XCTAssertEqual(byDay.map(\.key), ["2026-10-06", "2026-10-08"], "\(range)")
            XCTAssertEqual(byDay.map(\.seconds), [2.0 * 3600, 3.0 * 3600], "\(range)")

            let evidence = try store.evidence(in: range, groupBy: .day, now: now)
            XCTAssertEqual(evidence.map(\.key), ["2026-10-06", "2026-10-08", "2026-10-09"], "\(range)")
        }
        // The same dates whatever zone the process runs in.
        store.processZone = TimeZone(identifier: "Pacific/Honolulu")!
        XCTAssertEqual(try store.timesheet(in: thisWeek, now: now).map(\.date), ["2026-10-06", "2026-10-08"])
    }

    func testAnEntryCrossingMidnightIsOneEntryAndTwoTimesheetRows() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        // Tuesday 23:00 to Wednesday 01:00 in Tokyo, logged in Tokyo's zone from New York.
        var late = NewTimeEntry(start: TimeRange.parseDate("2026-10-06T23:00:00+09:00")!,
                                end: TimeRange.parseDate("2026-10-07T01:30:00+09:00")!, projectID: acme.id,
                                title: "cutover", origin: .manual)
        late.zone = tokyo
        try store.createEntry(late, now: now)
        let range = ReportRange.localDates(LocalDate("2026-10-06")!...LocalDate("2026-10-07")!)

        XCTAssertEqual(try store.timeEntries(in: range, now: now).count, 1)
        let byDay = try store.summary(in: range, groupBy: .day, now: now)
        XCTAssertEqual(byDay.groups.map(\.key), ["2026-10-06", "2026-10-07"])
        XCTAssertEqual(byDay.groups.map(\.seconds), [3600, 5400])
        let timesheet = try store.timesheet(in: range, now: now)
        XCTAssertEqual(timesheet.map(\.date), ["2026-10-06", "2026-10-07"])
        XCTAssertEqual(timesheet.map(\.hours), [1, 1.5])
        XCTAssertEqual(timesheet.map(\.notes), [["cutover"], ["cutover"]])

        // Asking for Wednesday alone counts only Wednesday's part.
        let wednesday = ReportRange.localDates(LocalDate("2026-10-07")!...LocalDate("2026-10-07")!)
        XCTAssertEqual(try store.timesheet(in: wednesday, now: now).map(\.hours), [1.5])
        XCTAssertEqual(try store.summary(in: wednesday, groupBy: .project, now: now).seconds, 5400)
    }
}
