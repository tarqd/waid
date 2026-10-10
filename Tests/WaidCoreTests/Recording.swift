import Foundation
@testable import WaidCore

extension Store {
    /// Records `sample` in front, with input throughout, from `start` to
    /// `end`, through the recorder as the daemon would: a focus observation
    /// and the active time that makes it present. Returns the id of the focus
    /// observation starting at `start`. A `projectID` is assigned afterwards.
    @discardableResult
    func work(
        _ sample: ActivitySample, from start: Date, to end: Date, zone: TimeZone? = nil, projectID: Int64? = nil
    ) throws -> Int64 {
        let recorder = ActivityRecorder(store: self, interval: 60)
        var sample = sample
        sample.idleSeconds = 0
        for t in stride(from: start, to: end, by: 60) { try recorder.record(.sample(sample), at: t, zone: zone) }
        try recorder.record(.sample(sample), at: end, zone: zone)
        let ids = try observations(.focus, in: DateInterval(start: start - 1, end: end + 1))
            .filter { $0.start >= start && $0.start <= end && $0.source == Source.window }.map(\.id)
        if let projectID { try assign(activityIDs: ids, projectID: projectID) }
        return ids[0]
    }
}
