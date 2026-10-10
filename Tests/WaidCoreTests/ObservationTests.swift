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
}
