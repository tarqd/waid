import Foundation

/// Turns a stream of point-in-time samples into contiguous spans.
///
/// Consecutive samples with the same app/title/url/path extend the open focus
/// observation. A change, a gap longer than `maxGap` (sleep, daemon restart),
/// or the user going idle closes it.
public final class ActivityRecorder {
    private struct Key: Equatable {
        var bundleID, appName, title, url, path: String?
        init(_ s: ActivitySample) {
            bundleID = s.bundleID; appName = s.appName; title = s.title; url = s.url; path = s.path
        }
    }

    private let store: Store
    public let maxGap: TimeInterval
    public let idleThreshold: TimeInterval
    private var current: (id: Int64, key: Key, start: Date, end: Date)?
    private var closedLeftovers = false

    public init(store: Store, maxGap: TimeInterval = 30, idleThreshold: TimeInterval = 180) {
        self.store = store
        self.maxGap = maxGap
        self.idleThreshold = idleThreshold
    }

    /// Records one sample, stamping new observations with `zone` (else the
    /// store's process zone). Pass a nil sample when nothing should be
    /// tracked (screen locked, system going to sleep).
    public func record(_ sample: ActivitySample?, at now: Date, zone: TimeZone? = nil) throws {
        if !closedLeftovers {
            // Whatever a previous run left open ended at its last heartbeat.
            try store.closeOpenObservations()
            closedLeftovers = true
        }
        guard let sample, sample.idleSeconds < idleThreshold else {
            if let current {
                // Trim the idle tail: input stopped `idleSeconds` ago, but we
                // kept extending the observation until the threshold tripped.
                var end = current.end
                if let sample {
                    let lastInput = now.addingTimeInterval(-sample.idleSeconds)
                    if lastInput < end { end = max(current.start, lastInput) }
                }
                try store.close(activityID: current.id, end: end)
            }
            current = nil
            return
        }

        let key = Key(sample)
        if var current, current.key == key, now.timeIntervalSince(current.end) <= maxGap {
            current.end = now
            try store.setEnd(activityID: current.id, end: now)
            self.current = current
        } else {
            if let current {
                // A switch within the gap means the previous observation
                // lasted until now; after a longer gap it ended at its last
                // sample.
                let end = now.timeIntervalSince(current.end) <= maxGap ? now : current.end
                try store.close(activityID: current.id, end: end)
            }
            let id = try store.insertActivity(start: now, end: nil, source: Source.window, sample: sample, zone: zone)
            current = (id, key, now, now)
        }
    }
}
