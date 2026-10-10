import Foundation

/// Writes the focus, active and locked streams (GLOSSARY.md: Observation)
/// from one signal at a time.
///
/// - focus: consecutive samples with the same app/title/url/path extend the
///   open observation. A change or a gap longer than `maxGap` (a missed
///   heartbeat, a daemon restart) closes it. Nothing is trimmed: whether you
///   were present is derived from the active stream when you ask
///   (GLOSSARY.md: Present).
/// - active: extends while input was seen within the last `interval`, and
///   closes at the last input instant once it wasn't.
/// - locked: lock or sleep closes focus and active and opens a locked
///   observation; wake or unlock closes it. Sleep delivers no heartbeats, so
///   closing on wake covers the gap.
///
/// Every observation has one local date in the zone it is stamped with:
/// before extending one past local midnight, it is closed at that midnight
/// and continued in a new one.
public final class ActivityRecorder {
    /// One thing the daemon saw.
    public enum Signal: Equatable, Sendable {
        case sample(ActivitySample)
        case lock, sleep, wake, unlock
    }

    private struct Key: Equatable {
        var bundleID, appName, title, url, path: String?
        init(_ s: ActivitySample) {
            bundleID = s.bundleID; appName = s.appName; title = s.title; url = s.url; path = s.path
        }
    }

    /// An observation this recorder has open, as it was last written.
    private struct Open {
        var stream: Observation.Stream
        var id: Int64
        var start: Date
        var end: Date
        var localDate: LocalDate
        /// What was in front, for focus.
        var sample: ActivitySample?
    }

    private let store: Store
    /// How often the daemon samples. Input within one interval is active.
    public let interval: TimeInterval
    /// The heartbeat window: three intervals without a sample end an observation.
    public var maxGap: TimeInterval { interval * 3 }
    private var focus: Open?
    private var active: Open?
    private var locked: Open?
    private var closedLeftovers = false

    public init(store: Store, interval: TimeInterval = 5) {
        self.store = store
        self.interval = interval
    }

    /// Records one signal at `now`, stamping observations with `zone` (else
    /// the store's process zone).
    public func record(_ signal: Signal, at now: Date, zone: TimeZone? = nil) throws {
        let zone = zone ?? store.processZone
        try store.db.transaction {
            if !closedLeftovers {
                // Whatever a previous run left open ended at its last heartbeat.
                try store.closeOpenObservations()
                closedLeftovers = true
            }
            switch signal {
            case .sample(let sample):
                if var held = locked {
                    // Still locked: only the locked observation's heartbeat moves.
                    try extend(&held, to: now, zone: zone)
                    locked = held
                } else {
                    try recordFocus(sample, at: now, zone: zone)
                    try recordActive(sample, at: now, zone: zone)
                }
            case .lock, .sleep:
                if var held = locked {
                    try extend(&held, to: now, zone: zone)
                    locked = held
                    return
                }
                for open in [focus, active].compactMap({ $0 }) {
                    var open = open
                    try close(&open, at: withinGap(open, now) ? now : open.end, zone: zone)
                }
                focus = nil
                active = nil
                locked = try begin(.locked, at: now, zone: zone)
            case .wake, .unlock:
                guard var held = locked else { return }
                try close(&held, at: now, zone: zone)
                locked = nil
            }
        }
    }

    private func recordFocus(_ sample: ActivitySample, at now: Date, zone: TimeZone) throws {
        if var open = focus, open.sample.map(Key.init) == Key(sample), withinGap(open, now) {
            try extend(&open, to: now, zone: zone)
            focus = open
            return
        }
        if var open = focus {
            // A switch within the gap means the previous observation lasted
            // until now; after a longer gap it ended at its last sample.
            try close(&open, at: withinGap(open, now) ? now : open.end, zone: zone)
        }
        focus = try begin(.focus, at: now, sample: sample, zone: zone)
    }

    private func recordActive(_ sample: ActivitySample, at now: Date, zone: TimeZone) throws {
        guard sample.idleSeconds <= interval else {
            if var open = active {
                // Input stopped `idleSeconds` ago: that's where it ended.
                try close(&open, at: now.addingTimeInterval(-sample.idleSeconds), zone: zone)
            }
            active = nil
            return
        }
        if var open = active, withinGap(open, now) {
            try extend(&open, to: now, zone: zone)
            active = open
            return
        }
        if var open = active { try close(&open, at: open.end, zone: zone) }
        active = try begin(.active, at: now, zone: zone)
    }

    private func withinGap(_ open: Open, _ now: Date) -> Bool {
        now.timeIntervalSince(open.end) <= maxGap
    }

    private func begin(
        _ stream: Observation.Stream, at start: Date, sample: ActivitySample? = nil, zone: TimeZone
    ) throws -> Open {
        let id = try store.insertObservation(stream, start: start, end: nil, sample: sample, zone: zone)
        return Open(stream: stream, id: id, start: start, end: start, localDate: LocalDate(start, in: zone), sample: sample)
    }

    /// Moves `open`'s heartbeat to `instant`, first continuing it in a new
    /// observation at each local midnight it would cross.
    private func extend(_ open: inout Open, to instant: Date, zone: TimeZone) throws {
        try splitAtMidnight(&open, before: instant, zone: zone)
        try store.setEnd(observationID: open.id, end: instant)
        open.end = instant
    }

    /// Closes `open` at `end`, first continuing it past any local midnight
    /// before `end`. An `end` before its start means it never held any time,
    /// as when input stopped before the midnight it was continued at, so it
    /// is deleted instead.
    private func close(_ open: inout Open, at end: Date, zone: TimeZone) throws {
        if end > open.end { try splitAtMidnight(&open, before: end, zone: zone) }
        guard end >= open.start else {
            try store.discard(observationID: open.id)
            return
        }
        try store.close(observationID: open.id, end: end)
        open.end = end
    }

    private func splitAtMidnight(_ open: inout Open, before instant: Date, zone: TimeZone) throws {
        while LocalDate(instant, in: zone) != open.localDate {
            let next = open.localDate.adding(days: 1)
            let midnight = next.start(in: zone)
            // A zone change can move the date without a midnight in between.
            guard midnight > open.start, midnight <= instant else { return }
            try store.close(observationID: open.id, end: midnight)
            open = try begin(open.stream, at: midnight, sample: open.sample, zone: zone)
            open.localDate = next
        }
    }
}
