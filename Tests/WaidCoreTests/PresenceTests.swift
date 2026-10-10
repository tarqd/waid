import Foundation
import XCTest
@testable import WaidCore

/// Presence is derived when you ask (GLOSSARY.md: Present, Activity, Away):
/// the recorder keeps every stream untrimmed, and the idle threshold decides
/// at query time how much of a window activity counts.
final class PresenceTests: XCTestCase {
    var store: Store!
    let t0 = TimeRange.parseDate("2026-10-09T09:00:00Z")!
    let editor = ActivitySample(appName: "Xcode", title: "main.swift")
    var hour: DateInterval { DateInterval(start: t0, duration: 3600) }

    override func setUpWithError() throws {
        store = try Store(path: ":memory:")
    }

    func threshold(_ seconds: Int) throws {
        try store.setValue(String(seconds), forKey: "idle_threshold_seconds")
    }

    /// Samples of `editor` every 5 s from `from` through `through` seconds
    /// after `t0`; with `idleFrom`, the last input was at that offset.
    func record(_ recorder: ActivityRecorder, from: Double, through: Double, idleFrom: Double? = nil) throws {
        for t in stride(from: from, through: through, by: 5) {
            var s = editor
            if let idleFrom { s.idleSeconds = t - idleFrom }
            try recorder.record(.sample(s), at: t0 + t)
        }
    }

    func testTheSameFactsCountedAtTwoThresholdsGiveDifferentDurations() throws {
        let recorder = ActivityRecorder(store: store, interval: 5)
        // Ten minutes of input, ten minutes reading without input, ten more of input.
        try record(recorder, from: 0, through: 600)
        try record(recorder, from: 605, through: 1195, idleFrom: 600)
        try record(recorder, from: 1200, through: 1800)

        try threshold(180)
        let short = try store.activities(in: hour)
        XCTAssertEqual(short.map { [$0.start, $0.end!].map { $0.timeIntervalSince(t0) } }, [[0, 1800]],
                       "the full extent, never trimmed")
        XCTAssertEqual(short.map { $0.duration() }, [1200], "only the present time")
        XCTAssertEqual(try store.evidence(in: .instants(hour), groupBy: .app, now: t0 + 1800),
                       [Store.EvidenceRow(key: "Xcode", secondsBySource: [Source.window: 1200])])

        try threshold(900)
        XCTAssertEqual(try store.activities(in: hour).map { $0.duration() }, [1800], "the pause is bridged")
        XCTAssertEqual(try store.evidence(in: .instants(hour), groupBy: .app, now: t0 + 1800),
                       [Store.EvidenceRow(key: "Xcode", secondsBySource: [Source.window: 1800])])
    }
}
