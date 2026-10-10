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
        XCTAssertEqual(try store.evidence(in: .instants(hour), groupBy: .app),
                       [Store.EvidenceRow(key: "Xcode", secondsBySource: [Source.window: 1200])])

        try threshold(900)
        XCTAssertEqual(try store.activities(in: hour).map { $0.duration() }, [1800], "the pause is bridged")
        XCTAssertEqual(try store.evidence(in: .instants(hour), groupBy: .app),
                       [Store.EvidenceRow(key: "Xcode", secondsBySource: [Source.window: 1800])])
    }

    func testLockedTimeIsSubtractedFromWindowActivitiesButNotFromAgentObservations() throws {
        // Input throughout, but the screen was locked for two minutes in the
        // middle, shorter than the threshold, so present(T) alone bridges it.
        try store.insertActivity(start: t0, end: t0 + 1800, source: Source.window, sample: editor)
        try store.insertObservation(.active, start: t0, end: t0 + 600)
        try store.insertObservation(.locked, start: t0 + 600, end: t0 + 720)
        try store.insertObservation(.active, start: t0 + 720, end: t0 + 1800)
        try store.upsertExternal(source: Source.agent("claude-code"), externalID: "s1", start: t0, end: t0 + 1800,
                                 title: "refactor", path: "/src/waid")

        let activities = try store.activities(in: hour)
        XCTAssertEqual(activities.map(\.source), [Source.window, Source.agent("claude-code")])
        XCTAssertEqual(activities.map { $0.duration() }, [1680, 1800], "the agent counts in full, locked or not")
        XCTAssertEqual(try store.evidence(in: .instants(hour), groupBy: .source).map(\.secondsBySource),
                       [[Source.agent("claude-code"): 1800], [Source.window: 1680]])
    }

    func testAnAgentAloneNeverMakesYouPresent() throws {
        let acme = try store.ensureProject("Acme / Phase 2")
        try store.addRule(projectID: acme.id, field: .path, op: .prefix, pattern: "/src/acme")
        try store.upsertExternal(source: Source.agent("claude-code"), externalID: "s1", start: t0, end: t0 + 3600,
                                 title: "integration", path: "/src/acme")

        XCTAssertEqual(try store.evidence(in: .instants(hour), groupBy: .project),
                       [Store.EvidenceRow(key: "Acme / Phase 2", secondsBySource: [Source.agent("claude-code"): 3600])])
        let unlogged = try store.unloggedTime(in: .instants(hour), groupBy: .project, now: t0 + 3600)
        XCTAssertEqual(unlogged.groups, [])
        XCTAssertEqual(unlogged.seconds, 0)
    }

    func testAwayTimeIsTheGapBetweenInputsAndTheLockedStretch() throws {
        let recorder = ActivityRecorder(store: store, interval: 5)
        // Input, ten minutes away from the keyboard, input, then locked for 20 minutes.
        try record(recorder, from: 0, through: 300)
        try record(recorder, from: 305, through: 895, idleFrom: 300)
        try record(recorder, from: 900, through: 1200)
        try recorder.record(.lock, at: t0 + 1200)
        try recorder.record(.unlock, at: t0 + 2400)
        try record(recorder, from: 2405, through: 2700)

        let away = try store.away(in: hour)
        XCTAssertEqual(away.map { [$0.start, $0.end].map { $0.timeIntervalSince(t0) } }, [[300, 900], [1200, 2400]])

        try threshold(900)
        XCTAssertEqual(try store.away(in: hour).map { [$0.start, $0.end].map { $0.timeIntervalSince(t0) } },
                       [[1200, 2400]], "a pause within the threshold isn't away; locked time always is")
    }
}
