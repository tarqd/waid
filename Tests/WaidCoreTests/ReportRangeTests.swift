import Foundation
import XCTest
@testable import WaidCore

/// Named ranges and date-only inputs select rows by the Local date stored on
/// them (GLOSSARY.md, ADR-0002), so a range and the day labels inside it
/// agree. Explicit timestamps stay instants.
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
        store.processZone = newYork
    }

    private func entry(_ start: String, _ end: String, in zone: TimeZone, project: Project) throws {
        var new = NewTimeEntry(start: TimeRange.parseDate(start)!, end: TimeRange.parseDate(end)!,
                               projectID: project.id, origin: .manual)
        new.zone = zone
        try store.createEntry(new, now: now)
    }

    private func observe(_ start: String, _ end: String, in zone: TimeZone, project: Project? = nil) throws {
        try store.work(ActivitySample(appName: "Mail"), from: TimeRange.parseDate(start)!, to: TimeRange.parseDate(end)!,
                       zone: zone, projectID: project?.id)
    }

    private func dates(_ first: String, _ last: String? = nil) -> ReportRange {
        .localDates(LocalDate(first)!...LocalDate(last ?? first)!)
    }

    func testADateSelectsExactlyTheObservationsStampedWithIt() throws {
        // Friday 09:00 in New York, stamped Friday.
        try observe("2026-10-09T09:00:00-04:00", "2026-10-09T10:00:00-04:00", in: newYork)
        // Saturday 00:30 in Tokyo is Friday 11:30 in New York, but it is stamped Saturday.
        try observe("2026-10-10T00:30:00+09:00", "2026-10-10T01:00:00+09:00", in: tokyo)
        let fridayEvening = TimeRange.parseDate("2026-10-09T18:00:00-04:00")!

        for range in [
            try TimeRange.resolve(range: "today", start: nil, end: nil, now: fridayEvening, calendar: newYorkCalendar),
            try TimeRange.resolve(range: nil, start: "2026-10-09", end: nil, now: fridayEvening, calendar: newYorkCalendar),
        ] {
            XCTAssertEqual(try store.activities(in: range).map(\.localDate), ["2026-10-09"])
            let evidence = try store.evidence(in: range, groupBy: .day)
            XCTAssertEqual(evidence.map(\.key), ["2026-10-09"])
            XCTAssertEqual(evidence.map { $0.secondsBySource[Source.window] }, [3600])
        }
        XCTAssertEqual(try store.evidence(in: dates("2026-10-10"), groupBy: .day).map(\.key),
                       ["2026-10-10"])
    }

    func testTokyoMondayMorningIsInThisWeekQueriedFromNewYork() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        // Monday 08:00 in Tokyo is Sunday 19:00 in New York.
        try entry("2026-10-05T08:00:00+09:00", "2026-10-05T09:00:00+09:00", in: tokyo, project: acme)
        // Sunday 22:00 in Tokyo is last week, though it is Sunday morning in New York.
        try entry("2026-10-04T22:00:00+09:00", "2026-10-04T23:00:00+09:00", in: tokyo, project: acme)

        let thisWeek = try TimeRange.resolve(range: "this_week", start: nil, end: nil, now: now, calendar: newYorkCalendar)
        let summary = try store.summary(in: thisWeek, groupBy: .day, now: now)
        XCTAssertEqual(summary.groups.map(\.key), ["2026-10-05"])
        XCTAssertEqual(summary.seconds, 3600)

        let lastWeek = try TimeRange.resolve(range: "last_week", start: nil, end: nil, now: now, calendar: newYorkCalendar)
        XCTAssertEqual(try store.timesheet(in: lastWeek, now: now).map(\.date), ["2026-10-04"])
    }

    func testWeeksStartOnMondayUnderAnyLocale() throws {
        let sunday = TimeRange.parseDate("2026-10-11T12:00:00-04:00")!
        for (locale, firstWeekday) in [("en_US", 1), ("fr_FR", 2), ("ar_EG", 7)] {
            var calendar = newYorkCalendar
            calendar.locale = Locale(identifier: locale)
            calendar.firstWeekday = firstWeekday
            XCTAssertEqual(try TimeRange.resolve(range: "this_week", start: nil, end: nil, now: sunday, calendar: calendar),
                           dates("2026-10-05", "2026-10-11"), locale)
            XCTAssertEqual(try TimeRange.resolve(range: "last_week", start: nil, end: nil, now: sunday, calendar: calendar),
                           dates("2026-09-28", "2026-10-04"), locale)
        }
    }

    func testTimestampsWithAnOffsetSelectByInstant() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        try entry("2026-10-05T08:00:00+09:00", "2026-10-05T10:00:00+09:00", in: tokyo, project: acme)

        // From Sunday 19:30 in New York: the last 90 minutes of the Tokyo Monday morning.
        let range = try TimeRange.resolve(range: nil, start: "2026-10-04T19:30:00-04:00", end: "2026-10-06T00:00:00Z",
                                          now: now, calendar: newYorkCalendar)
        let summary = try store.summary(in: range, groupBy: .day, now: now)
        XCTAssertEqual(summary.groups.map(\.key), ["2026-10-05"], "labelled with the entry's own date")
        XCTAssertEqual(summary.seconds, 90 * 60)
    }

    /// Flying home from Tokyo on Friday night lives Friday and Saturday twice.
    private func flyingHome(_ project: Project) throws {
        // The recorder closes and reopens at each local midnight.
        try observe("2026-10-09T22:00:00+09:00", "2026-10-10T01:00:00+09:00", in: tokyo, project: project)
        // Landed: Saturday 01:00 in Tokyo is Friday 12:00 in New York.
        try observe("2026-10-09T12:00:00-04:00", "2026-10-10T02:00:00-04:00", in: newYork, project: project)
    }

    func testADateLivedInTwoZonesSelectsItsTimeInBoth() throws {
        let travel = try store.ensureProject("Travel")
        try flyingHome(travel)
        let acme = try store.ensureProject("Acme / Phase 2")
        try entry("2026-10-09T23:00:00+09:00", "2026-10-09T23:30:00+09:00", in: tokyo, project: acme)
        try entry("2026-10-09T13:00:00-04:00", "2026-10-09T13:30:00-04:00", in: newYork, project: acme)

        // Saturday: 00:00-01:00 in Tokyo, then 00:00-02:00 in New York.
        let saturday = try TimeRange.resolve(range: nil, start: "2026-10-10", end: "2026-10-10", now: now, calendar: newYorkCalendar)
        let evidence = try store.evidence(in: saturday, groupBy: .day)
        XCTAssertEqual(evidence.map(\.key), ["2026-10-10"])
        XCTAssertEqual(evidence.map { $0.secondsBySource[Source.window] }, [3.0 * 3600])

        // Friday: 22:00-24:00 in Tokyo, then 12:00-24:00 in New York; an hour of it is logged.
        let friday = dates("2026-10-09")
        let unlogged = try store.unloggedTime(in: friday, groupBy: .day, now: now)
        XCTAssertEqual(unlogged.groups.map(\.key), ["2026-10-09"])
        XCTAssertEqual(unlogged.seconds, 13.0 * 3600)
        XCTAssertEqual(try store.timesheet(in: friday, now: now).map(\.hours), [1])
    }

    func testSpansAreListedAndSuggestedOnlyOnTheirLocalDate() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        // Saturday 00:00-00:40 in Tokyo is Friday 11:00-11:40 in New York.
        try observe("2026-10-10T00:00:00+09:00", "2026-10-10T00:40:00+09:00", in: tokyo, project: acme)
        try entry("2026-10-10T00:45:00+09:00", "2026-10-10T00:55:00+09:00", in: tokyo, project: acme)

        let friday = dates("2026-10-09")
        XCTAssertEqual(try store.activities(in: friday).count, 0)
        XCTAssertEqual(try store.timeEntries(in: friday, now: now).count, 0)
        XCTAssertEqual(try store.unloggedTime(in: friday, groupBy: .day, now: now).seconds, 0)
        XCTAssertEqual(try store.suggestEntries(in: friday, now: now).count, 0)

        let saturday = dates("2026-10-10")
        XCTAssertEqual(try store.activities(in: saturday).count, 1)
        XCTAssertEqual(try store.timeEntries(in: saturday, now: now).count, 1)
        // Unlogged time is what a suggestion would offer.
        let unlogged = try store.unloggedTime(in: saturday, groupBy: .day, now: now)
        let suggested = try store.suggestEntries(in: saturday, now: now)
        XCTAssertEqual(unlogged.seconds, 40 * 60)
        XCTAssertEqual(suggested.map { $0.entry.duration(now: now) }, [40.0 * 60])
    }

    func testARunningEntryIsSelectedOnEveryDateUntilItStops() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        // Started Friday 23:00 in New York and still running at Saturday noon.
        try store.createEntry(NewTimeEntry(start: TimeRange.parseDate("2026-10-09T23:00:00-04:00")!, end: nil,
                                           projectID: acme.id, origin: .timer), now: now)

        let today = try TimeRange.resolve(range: "today", start: nil, end: nil, now: now, calendar: newYorkCalendar)
        XCTAssertEqual(try store.summary(in: today, groupBy: .day, now: now).groups.map(\.seconds), [12.0 * 3600])
        XCTAssertEqual(try store.summary(in: dates("2026-10-09", "2026-10-11"), groupBy: .day, now: now).groups.map(\.key),
                       ["2026-10-09", "2026-10-10"])
        XCTAssertEqual(try store.timeEntries(in: dates("2026-10-08"), now: now).count, 0)
    }
}
