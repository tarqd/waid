import Foundation
import XCTest
@testable import WaidCore

/// A span's day is its Local date: the date where you were when it happened,
/// from the zone history (GLOSSARY.md, ADR-0001), not the zone the report runs in.
final class LocalDateTests: XCTestCase {
    var store: Store!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let newYork = TimeZone(identifier: "America/New_York")!
    /// Monday 2026-10-05 00:00 in Tokyo.
    let mondayTokyo = TimeRange.parseDate("2026-10-05T00:00:00+09:00")!
    /// Saturday after the trip, back in New York.
    let now = TimeRange.parseDate("2026-10-10T12:00:00-04:00")!
    var week: DateInterval { DateInterval(start: mondayTokyo - 86400, end: now) }
    /// The machine's zone when the report runs: New York.
    var newYorkCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        return calendar
    }

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
    }

    private func entry(_ start: String, _ end: String, project: Project) throws {
        try store.createEntry(NewTimeEntry(start: TimeRange.parseDate(start)!, end: TimeRange.parseDate(end)!,
                                           projectID: project.id, origin: .manual), now: now)
    }

    func testTokyoWeekKeepsItsTokyoDatesAfterFlyingHome() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        try store.recordZone(tokyo, now: mondayTokyo)
        // Tuesday morning and Thursday evening in Tokyo: both straddle a New York midnight.
        try entry("2026-10-06T08:00:00+09:00", "2026-10-06T10:00:00+09:00", project: acme)
        try entry("2026-10-08T12:00:00+09:00", "2026-10-08T15:00:00+09:00", project: acme)
        try store.recordZone(newYork, now: TimeRange.parseDate("2026-10-09T18:00:00-04:00")!)

        let timesheet = try store.timesheet(in: week, calendar: newYorkCalendar, now: now)
        XCTAssertEqual(timesheet.map(\.date), ["2026-10-06", "2026-10-08"])
        XCTAssertEqual(timesheet.map(\.hours), [2, 3])

        let byDay = try store.summary(in: week, groupBy: .day, calendar: newYorkCalendar, now: now).groups
        XCTAssertEqual(byDay.map(\.key), ["2026-10-06", "2026-10-08"])
        XCTAssertEqual(byDay.map(\.seconds), [2.0 * 3600, 3.0 * 3600])
    }

    func testSpanCrossingAZoneChangeIsSplitAtTheChangeThenAtLocalMidnight() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        try store.recordZone(tokyo, now: mondayTokyo)
        // Flying home: Friday 22:00 in Tokyo until Saturday 02:00 in New York.
        let start = TimeRange.parseDate("2026-10-09T22:00:00+09:00")!
        let end = TimeRange.parseDate("2026-10-10T02:00:00-04:00")!
        // Landed and noticed at Saturday 01:00 in Tokyo, which is Friday 12:00 in New York.
        try store.recordZone(newYork, now: TimeRange.parseDate("2026-10-10T01:00:00+09:00")!)
        let project = try store.ensureProject("Travel")
        try store.insertActivity(start: start, end: end, source: Source.window,
                                 sample: ActivitySample(appName: "Mail"), projectID: project.id)

        // Tokyo: Fri 22-24 (2 h) + Sat 00-01 (1 h); New York: Fri 12-24 (12 h) + Sat 00-02 (2 h).
        let evidence = try store.evidence(in: week, groupBy: .day, calendar: utc, now: now)
        XCTAssertEqual(evidence.map(\.key), ["2026-10-09", "2026-10-10"])
        XCTAssertEqual(evidence.map { $0.secondsBySource[Source.window] }, [14.0 * 3600, 3.0 * 3600])

        let unlogged = try store.unloggedTime(in: week, groupBy: .day, calendar: utc, now: now).groups
        XCTAssertEqual(unlogged.map(\.key), ["2026-10-09", "2026-10-10"])
        XCTAssertEqual(unlogged.map(\.seconds), [14.0 * 3600, 3.0 * 3600])
    }

    func testTimeBeforeTheFirstZoneRecordUsesTheFirstRecordedZone() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        // Logged before waid ever recorded a zone: Monday 22:00-23:00 in Tokyo is Monday 09:00 in New York.
        try entry("2026-10-05T22:00:00+09:00", "2026-10-05T23:00:00+09:00", project: acme)
        // Tuesday 08:00 in Tokyo, one hour after the first record: that is Monday evening in New York.
        try entry("2026-10-06T08:00:00+09:00", "2026-10-06T09:00:00+09:00", project: acme)
        try store.recordZone(newYork, now: TimeRange.parseDate("2026-10-06T07:00:00+09:00")!)

        var tokyoCalendar = Calendar(identifier: .gregorian)
        tokyoCalendar.timeZone = tokyo
        let timesheet = try store.timesheet(in: week, calendar: tokyoCalendar, now: now)
        XCTAssertEqual(timesheet.map(\.date), ["2026-10-05"], "both in New York, the first recorded zone")
        XCTAssertEqual(timesheet.map(\.hours), [2])
    }

    func testWithoutAnyZoneHistoryTheCalendarZoneIsUsed() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        try entry("2026-10-06T08:00:00+09:00", "2026-10-06T09:00:00+09:00", project: acme)

        XCTAssertEqual(try store.timesheet(in: week, calendar: newYorkCalendar, now: now).map(\.date), ["2026-10-05"])
    }
}
