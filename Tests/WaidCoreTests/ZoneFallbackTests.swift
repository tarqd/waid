import Foundation
import XCTest
@testable import WaidCore

/// Rows written without a zone of their own take the zone of the nearest
/// earlier observation, else the process zone (ADR-0002).
final class ZoneFallbackTests: XCTestCase {
    var store: Store!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let newYork = TimeZone(identifier: "America/New_York")!
    let editor = ActivitySample(bundleID: "com.apple.dt.Xcode", appName: "Xcode", title: "waid")
    /// 22:00 UTC on the 9th: 07:00 on the 10th in Tokyo, 18:00 on the 9th in New York.
    let late = TimeRange.parseDate("2026-10-09T22:00:00Z")!

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
        store.processZone = newYork
    }

    func testAnEntryWithoutAZoneTakesTheZoneOfTheNearestEarlierObservation() throws {
        try store.insertActivity(start: late - 3600, end: late - 1800, source: Source.window, sample: editor, zone: tokyo)

        let entry = try store.createEntry(NewTimeEntry(start: late, end: late + 1800, origin: .manual), now: late + 3600)

        XCTAssertEqual(entry.zone, "Asia/Tokyo")
        XCTAssertEqual(entry.startDate, "2026-10-10")
        XCTAssertEqual(entry.endDate, "2026-10-10")
    }

    func testAnEntryWithAZoneLandsOnThatZonesDate() throws {
        try store.insertActivity(start: late - 3600, end: late - 1800, source: Source.window, sample: editor, zone: newYork)
        var new = NewTimeEntry(start: late, end: late + 1800, origin: .manual)
        new.zone = tokyo

        let entry = try store.createEntry(new, now: late + 3600)

        XCTAssertEqual(entry.zone, "Asia/Tokyo")
        XCTAssertEqual(entry.startDate, "2026-10-10")
    }

    func testWithNoEarlierObservationAnEntryTakesTheProcessZone() throws {
        // Observed in Tokyo only after the entry starts.
        try store.insertActivity(start: late + 3600, end: late + 4000, source: Source.window, sample: editor, zone: tokyo)

        let entry = try store.createEntry(NewTimeEntry(start: late, end: late + 1800, origin: .manual), now: late + 7200)

        XCTAssertEqual(entry.zone, "America/New_York")
        XCTAssertEqual(entry.startDate, "2026-10-09")
    }

    func testAnUpdatedEntryGetsItsLocalDatesRecomputedInItsOwnZone() throws {
        var new = NewTimeEntry(start: late, end: late + 1800, origin: .manual)
        new.zone = tokyo
        let entry = try store.createEntry(new, now: late + 3600)

        // 16:00 to 17:00 UTC on the 10th: 01:00 to 02:00 on the 11th in Tokyo, still the 10th in New York.
        var move = TimeEntryChanges()
        move.start = TimeRange.parseDate("2026-10-10T16:00:00Z")!
        move.end = .some(TimeRange.parseDate("2026-10-10T17:00:00Z")!)
        let moved = try store.updateEntry(id: entry.id, move, now: late + 86400)

        XCTAssertEqual(moved.zone, "Asia/Tokyo")
        XCTAssertEqual(moved.startDate, "2026-10-11")
        XCTAssertEqual(moved.endDate, "2026-10-11")
    }

    func testAnEntryUpdatedWithAZoneMovesToThatZonesDates() throws {
        let entry = try store.createEntry(NewTimeEntry(start: late, end: late + 1800, origin: .manual), now: late + 3600)
        XCTAssertEqual(entry.startDate, "2026-10-09")

        var rezone = TimeEntryChanges()
        rezone.zone = tokyo
        let moved = try store.updateEntry(id: entry.id, rezone, now: late + 3600)

        XCTAssertEqual(moved.zone, "Asia/Tokyo")
        XCTAssertEqual(moved.startDate, "2026-10-10")
        XCTAssertEqual(moved.endDate, "2026-10-10")
    }

    func testAnImportedAgentSegmentTakesTheNearestEarlierObservationsZone() throws {
        // Transcripts carry UTC timestamps. One session, two segments:
        // 22:00Z on the 9th (after a Tokyo observation) and 14:00Z on the 10th
        // (after flying home to New York).
        let transcript = """
            {"type":"user","sessionId":"s1","cwd":"/src/waid","timestamp":"2026-10-09T22:00:00Z","message":{"role":"user","content":"fix tests"}}
            {"type":"assistant","sessionId":"s1","cwd":"/src/waid","timestamp":"2026-10-09T22:10:00Z","message":{"role":"assistant","content":"ok"}}
            {"type":"user","sessionId":"s1","cwd":"/src/waid","timestamp":"2026-10-10T14:00:00Z","message":{"role":"user","content":"again"}}
            {"type":"assistant","sessionId":"s1","cwd":"/src/waid","timestamp":"2026-10-10T14:10:00Z","message":{"role":"assistant","content":"done"}}
            """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let projectDir = dir.appendingPathComponent("-src-waid")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(transcript.utf8).write(to: projectDir.appendingPathComponent("s1.jsonl"))
        store.processZone = TimeZone(identifier: "UTC")!
        try store.insertActivity(start: late - 3600, end: late - 1800, source: Source.window, sample: editor, zone: tokyo)
        let home = TimeRange.parseDate("2026-10-10T13:00:00Z")!
        try store.insertActivity(start: home, end: home + 600, source: Source.window, sample: editor, zone: newYork)

        let ingestor = ClaudeCodeIngestor(root: dir)
        try ingestor.ingest(into: store)
        try ingestor.ingest(into: store, full: true)

        let range = DateInterval(start: late - 86400, end: late + 2 * 86400)
        let agent = try store.activities(in: range, filter: { var f = Store.ActivityFilter(); f.sources = [ClaudeCodeIngestor.source]; return f }())
        XCTAssertEqual(agent.map(\.zone), ["Asia/Tokyo", "America/New_York"], "re-importing doesn't duplicate or re-zone")
        XCTAssertEqual(agent.map(\.localDate), ["2026-10-10", "2026-10-10"])
    }

    func testATimerTakesTheZoneOfTheNearestEarlierObservation() throws {
        try store.insertActivity(start: late - 600, end: late, source: Source.window, sample: editor, zone: tokyo)

        let timer = try store.startTimer(projectID: nil, now: late).started

        XCTAssertEqual(timer.zone, "Asia/Tokyo")
        XCTAssertEqual(timer.startDate, "2026-10-10")
    }
}
