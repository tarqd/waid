import Foundation

/// Presence is derived when you ask, not decided when waid records
/// (GLOSSARY.md: Present, Activity, Away). The recorder keeps the focus,
/// active and locked streams untrimmed; these read them back through the
/// idle threshold stored in `kv`, so changing it re-reads history.
extension Store {
    static let idleThresholdKey = "idle_threshold_seconds"
    static let defaultIdleThreshold: TimeInterval = 180

    /// The idle threshold T: the longest gap in input that still counts as
    /// present. Stored in `kv`, 180 s unless set.
    func idleThreshold() throws -> TimeInterval {
        try value(forKey: Self.idleThresholdKey).flatMap(TimeInterval.init) ?? Self.defaultIdleThreshold
    }

    /// The time in `range` you were present and the machine wasn't locked,
    /// and the locked time, both as disjoint intervals in order. Present(T)
    /// is read from active observations in `range` widened by T on both
    /// sides, so a gap at the edge is judged by the input on its far side.
    func presence(in range: DateInterval) throws -> (present: [DateInterval], locked: [DateInterval]) {
        let threshold = try idleThreshold()
        let widened = DateInterval(start: range.start - threshold, end: range.end + threshold)
        let active = try observations(.active, in: widened).filter { $0.source == Source.window }
        let locked = TimeAccounting.merge(
            try observations(.locked, in: range).filter { $0.source == Source.window }.map(\.interval))
        let present = TimeAccounting.present(active: active.map(\.interval), threshold: threshold)
        return (TimeAccounting.subtract(locked, from: present), locked)
    }

    /// Fills in each activity's counted intervals by the attribution rule
    /// (`TimeAccounting.counted`).
    func attribute(_ activities: [Activity]) throws -> [Activity] {
        let windows = activities.filter { $0.source == Source.window }.map(\.extent)
        let presence = try TimeAccounting.hull(TimeAccounting.merge(windows)).map(presence(in:)) ?? (present: [], locked: [])
        return activities.map { activity in
            var activity = activity
            activity.counted = TimeAccounting.counted(
                extent: activity.extent, source: activity.source, present: presence.present, locked: presence.locked)
            return activity
        }
    }

    /// Away time in `range` (GLOSSARY.md): observed time, while a window was
    /// in front or the machine was locked, that you weren't present for.
    /// Locked time is always away. Agent sessions say nothing about you, so
    /// they are not observed time here. Disjoint intervals, in order.
    public func away(in range: DateInterval) throws -> [DateInterval] {
        let focus = try observations(.focus, in: range).filter { $0.source == Source.window }
        let locked = try observations(.locked, in: range).filter { $0.source == Source.window }
        let observed = TimeAccounting.merge((focus + locked).flatMap { TimeAccounting.intersect($0.interval, with: [range]) })
        return TimeAccounting.subtract(try presence(in: range).present, from: observed)
    }
}

extension Observation {
    var interval: DateInterval { DateInterval(start: start, end: end) }
}

extension Activity {
    /// From the start to the end of the focus observation.
    var extent: DateInterval { DateInterval(start: start, end: max(start, end ?? start)) }
}
