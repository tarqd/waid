import Foundation
import XCTest
@testable import WaidCore

/// Named ranges and date-only inputs select spans by Local date (GLOSSARY.md,
/// ADR-0001), so a range and the day labels inside it agree. Explicit
/// timestamps stay instants.
final class ReportRangeTests: XCTestCase {
    var store: Store!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let newYork = TimeZone(identifier: "America/New_York")!
    /// Saturday 2026-10-10, back home in New York.
    let now = TimeRange.parseDate("2026-10-10T12:00:00-04:00")!
    /// The machine's calendar when the report runs: New York, in a locale whose weeks start on Sunday.
    var newYorkCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 1
        return calendar
    }

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
    }

    private func entry(_ start: String, _ end: String, project: Project) throws {
        try store.createEntry(NewTimeEntry(start: TimeRange.parseDate(start)!, end: TimeRange.parseDate(end)!,
                                           projectID: project.id, origin: .manual), now: now)
    }

    /// In Tokyo from before the week, flying home to New York on Wednesday.
    private func tokyoThenNewYork() throws {
        try store.recordZone(tokyo, now: TimeRange.parseDate("2026-10-01T00:00:00+09:00")!)
        try store.recordZone(newYork, now: TimeRange.parseDate("2026-10-07T12:00:00-04:00")!)
    }

    func testTokyoMondayMorningIsInThisWeekQueriedFromNewYork() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        try tokyoThenNewYork()
        // Monday 08:00 in Tokyo is Sunday 19:00 in New York.
        try entry("2026-10-05T08:00:00+09:00", "2026-10-05T09:00:00+09:00", project: acme)
        // Sunday 22:00 in Tokyo is last week, though it is Sunday morning in New York.
        try entry("2026-10-04T22:00:00+09:00", "2026-10-04T23:00:00+09:00", project: acme)

        let thisWeek = try TimeRange.resolve(range: "this_week", start: nil, end: nil, now: now, calendar: newYorkCalendar)
        let summary = try store.summary(in: thisWeek, groupBy: .day, calendar: newYorkCalendar, now: now)
        XCTAssertEqual(summary.groups.map(\.key), ["2026-10-05"])
        XCTAssertEqual(summary.seconds, 3600)

        let lastWeek = try TimeRange.resolve(range: "last_week", start: nil, end: nil, now: now, calendar: newYorkCalendar)
        XCTAssertEqual(try store.timesheet(in: lastWeek, calendar: newYorkCalendar, now: now).map(\.date), ["2026-10-04"])
    }

    func testWeeksStartOnMondayUnderAnyLocale() throws {
        let sunday = TimeRange.parseDate("2026-10-11T12:00:00-04:00")!
        for (locale, firstWeekday) in [("en_US", 1), ("fr_FR", 2), ("ar_EG", 7)] {
            var calendar = newYorkCalendar
            calendar.locale = Locale(identifier: locale)
            calendar.firstWeekday = firstWeekday
            XCTAssertEqual(try TimeRange.resolve(range: "this_week", start: nil, end: nil, now: sunday, calendar: calendar),
                           .localDates(LocalDate("2026-10-05")!...LocalDate("2026-10-11")!), locale)
            XCTAssertEqual(try TimeRange.resolve(range: "last_week", start: nil, end: nil, now: sunday, calendar: calendar),
                           .localDates(LocalDate("2026-09-28")!...LocalDate("2026-10-04")!), locale)
        }
    }

    func testTimestampsWithAnOffsetSelectByInstant() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        try tokyoThenNewYork()
        try entry("2026-10-05T08:00:00+09:00", "2026-10-05T10:00:00+09:00", project: acme)

        // From Sunday 19:30 in New York: the last 90 minutes of the Tokyo Monday morning.
        let range = try TimeRange.resolve(range: nil, start: "2026-10-04T19:30:00-04:00", end: "2026-10-06T00:00:00Z",
                                          now: now, calendar: newYorkCalendar)
        let summary = try store.summary(in: range, groupBy: .day, calendar: newYorkCalendar, now: now)
        XCTAssertEqual(summary.groups.map(\.key), ["2026-10-05"])
        XCTAssertEqual(summary.seconds, 90 * 60)
    }

    func testADateRepeatedByFlyingWestSelectsBothStretches() throws {
        try store.recordZone(tokyo, now: TimeRange.parseDate("2026-10-01T00:00:00+09:00")!)
        // Noticed the flight home at Saturday 01:00 in Tokyo, which is Friday 12:00 in New York.
        try store.recordZone(newYork, now: TimeRange.parseDate("2026-10-10T01:00:00+09:00")!)
        let project = try store.ensureProject("Travel")
        // Friday 22:00 in Tokyo until Saturday 02:00 in New York.
        try store.insertActivity(start: TimeRange.parseDate("2026-10-09T22:00:00+09:00")!,
                                 end: TimeRange.parseDate("2026-10-10T02:00:00-04:00")!, source: Source.window,
                                 sample: ActivitySample(appName: "Mail"), projectID: project.id)
        let acme = try store.ensureProject("Acme / Phase 2")
        try entry("2026-10-09T23:00:00+09:00", "2026-10-09T23:30:00+09:00", project: acme)
        try entry("2026-10-09T13:00:00-04:00", "2026-10-09T13:30:00-04:00", project: acme)

        // Saturday: 00:00-01:00 in Tokyo, then 00:00-02:00 in New York.
        let saturday = try TimeRange.resolve(range: nil, start: "2026-10-10", end: "2026-10-10", now: now, calendar: newYorkCalendar)
        let evidence = try store.evidence(in: saturday, groupBy: .day, calendar: newYorkCalendar, now: now)
        XCTAssertEqual(evidence.map(\.key), ["2026-10-10"])
        XCTAssertEqual(evidence.map { $0.secondsBySource[Source.window] }, [3.0 * 3600])

        // Friday: 22:00-24:00 in Tokyo, then 12:00-24:00 in New York; an hour of it is logged.
        let friday = try TimeRange.resolve(range: nil, start: "2026-10-09", end: nil, now: TimeRange.parseDate("2026-10-09T23:00:00-04:00")!,
                                           calendar: newYorkCalendar)
        let unlogged = try store.unloggedTime(in: friday, groupBy: .day, calendar: newYorkCalendar, now: now)
        XCTAssertEqual(unlogged.groups.map(\.key), ["2026-10-09"])
        XCTAssertEqual(unlogged.seconds, 13.0 * 3600)
        XCTAssertEqual(try store.timesheet(in: friday, calendar: newYorkCalendar, now: now).map(\.hours), [1])
    }

    func testSpansAreListedAndSuggestedOnlyOnTheirLocalDateWhenADateRepeats() throws {
        try store.recordZone(tokyo, now: TimeRange.parseDate("2026-10-01T00:00:00+09:00")!)
        // Noticed the flight home at Saturday 01:00 in Tokyo, which is Friday 12:00 in New York.
        try store.recordZone(newYork, now: TimeRange.parseDate("2026-10-10T01:00:00+09:00")!)
        let acme = try store.ensureProject("Acme / Phase 2")
        // Saturday 00:00-00:40 in Tokyo: after Friday in Tokyo, before Friday resumes in New York.
        try store.insertActivity(start: TimeRange.parseDate("2026-10-10T00:00:00+09:00")!,
                                 end: TimeRange.parseDate("2026-10-10T00:40:00+09:00")!, source: Source.window,
                                 sample: ActivitySample(appName: "Mail"), projectID: acme.id)
        try entry("2026-10-10T00:45:00+09:00", "2026-10-10T00:55:00+09:00", project: acme)

        let friday = ReportRange.localDates(LocalDate("2026-10-09")!...LocalDate("2026-10-09")!)
        XCTAssertEqual(try store.activities(in: friday, calendar: newYorkCalendar, now: now).count, 0)
        XCTAssertEqual(try store.timeEntries(in: friday, calendar: newYorkCalendar, now: now).count, 0)
        XCTAssertEqual(try store.unloggedTime(in: friday, groupBy: .day, calendar: newYorkCalendar, now: now).seconds, 0)
        XCTAssertEqual(try store.suggestEntries(in: friday, calendar: newYorkCalendar, now: now).count, 0)

        let saturday = ReportRange.localDates(LocalDate("2026-10-10")!...LocalDate("2026-10-10")!)
        XCTAssertEqual(try store.activities(in: saturday, calendar: newYorkCalendar, now: now).count, 1)
        XCTAssertEqual(try store.timeEntries(in: saturday, calendar: newYorkCalendar, now: now).count, 1)
        // Unlogged time is what a suggestion would offer.
        let unlogged = try store.unloggedTime(in: saturday, groupBy: .day, calendar: newYorkCalendar, now: now)
        let suggested = try store.suggestEntries(in: saturday, calendar: newYorkCalendar, now: now)
        XCTAssertEqual(unlogged.seconds, 40 * 60)
        XCTAssertEqual(suggested.map { $0.entry.duration(now: now) }, [40.0 * 60])
    }
}
