import Foundation
import XCTest
@testable import WaidCore

final class ZoneHistoryTests: XCTestCase {
    var store: Store!
    let t0 = TimeRange.parseDate("2026-10-05T00:00:00Z")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let newYork = TimeZone(identifier: "America/New_York")!

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
    }

    func testRecordsAZoneOnlyWhenItChanges() throws {
        XCTAssertTrue(try store.recordZone(tokyo, now: t0))
        XCTAssertFalse(try store.recordZone(tokyo, now: t0 + 3600), "same zone again adds nothing")
        XCTAssertTrue(try store.recordZone(newYork, now: t0 + 86400))
        XCTAssertFalse(try store.recordZone(newYork, now: t0 + 90000))

        XCTAssertEqual(try store.zoneHistory(), [
            ZoneChange(zone: tokyo, effectiveFrom: t0),
            ZoneChange(zone: newYork, effectiveFrom: t0 + 86400),
        ])
    }

    func testFirstRecordCoversAllEarlierTime() throws {
        XCTAssertNil(try store.zone(at: t0), "no history yet")
        try store.recordZone(tokyo, now: t0)
        try store.recordZone(newYork, now: t0 + 86400)

        XCTAssertEqual(try store.zone(at: t0 - 365 * 86400), tokyo, "history from before waid ran")
        XCTAssertEqual(try store.zone(at: t0), tokyo)
        XCTAssertEqual(try store.zone(at: t0 + 86399), tokyo)
        XCTAssertEqual(try store.zone(at: t0 + 86400), newYork, "a change applies from when it was noticed")
        XCTAssertEqual(try store.zone(at: t0 + 30 * 86400), newYork)
    }
}
