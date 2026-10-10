import Foundation

/// One record of the zone history: from `effectiveFrom` on, you were in `zone`.
/// See GLOSSARY.md **Zone history** and ADR-0001.
public struct ZoneChange: Equatable, Sendable {
    public var zone: TimeZone
    public var effectiveFrom: Date

    public init(zone: TimeZone, effectiveFrom: Date) {
        self.zone = zone
        self.effectiveFrom = effectiveFrom
    }
}

extension Store {
    /// Reports the zone you are in at `now`. A record is added only when it
    /// differs from the latest one; returns whether one was added. A change
    /// noticed late applies from when it was noticed.
    @discardableResult
    public func recordZone(_ zone: TimeZone = .current, now: Date = Date()) throws -> Bool {
        try db.transaction {
            let latest = try db.query(
                "SELECT zone FROM zone_history ORDER BY effective_ts DESC, id DESC LIMIT 1").first?.string("zone")
            guard latest != zone.identifier else { return false }
            try db.run("INSERT INTO zone_history(zone, effective_ts) VALUES(?, ?)", [zone.identifier, now])
            return true
        }
    }

    /// The zone you were in at `date`, per the zone history. Time before the
    /// first record is in the first recorded zone; nil only when nothing has
    /// been recorded yet.
    func zone(at date: Date) throws -> TimeZone? {
        let history = try zoneHistory()
        return (history.last { $0.effectiveFrom <= date } ?? history.first)?.zone
    }

    /// `calendar` set to the zone you were in at `now`, for resolving "today"
    /// and other named ranges; unchanged when no zone has been recorded.
    public func calendar(at now: Date, fallback calendar: Calendar = .current) throws -> Calendar {
        var calendar = calendar
        if let zone = try zone(at: now) { calendar.timeZone = zone }
        return calendar
    }

    /// The instants `range` covers: exactly its instants, or the times whose
    /// local date, per the zone history, falls in its dates. Disjoint, in order.
    func intervals(_ range: ReportRange, calendar: Calendar = .current) throws -> [DateInterval] {
        try localDates(fallback: calendar).intervals(range)
    }

    /// The first and last instants `range` covers, for echoing its bounds
    /// back to the caller; nil when it covers none. Spans are selected by
    /// `range` itself, never by these bounds: a repeated local date leaves a
    /// gap between them that belongs to another date.
    public func bounds(of range: ReportRange, calendar: Calendar = .current) throws -> DateInterval? {
        TimeAccounting.hull(try intervals(range, calendar: calendar))
    }

    /// Local dates per the zone history, falling back to `calendar`'s zone
    /// only when nothing has been recorded yet.
    func localDates(fallback calendar: Calendar) throws -> TimeAccounting.LocalDates {
        TimeAccounting.LocalDates(history: try zoneHistory(), fallback: calendar.timeZone)
    }

    /// The zone history, oldest first.
    public func zoneHistory() throws -> [ZoneChange] {
        try db.query("SELECT zone, effective_ts FROM zone_history ORDER BY effective_ts, id").compactMap { row in
            guard let id = row.string("zone"), let zone = TimeZone(identifier: id),
                  let from = row.date("effective_ts") else { return nil }
            return ZoneChange(zone: zone, effectiveFrom: from)
        }
    }
}
