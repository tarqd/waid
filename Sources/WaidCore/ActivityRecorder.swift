import Foundation

/// Turns a stream of point-in-time samples into contiguous spans.
///
/// Consecutive samples with the same app/title/url/path extend the current
/// span. A change, a gap longer than `maxGap` (sleep, daemon restart), or the
/// user going idle closes it.
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

    public init(store: Store, maxGap: TimeInterval = 30, idleThreshold: TimeInterval = 180) {
        self.store = store
        self.maxGap = maxGap
        self.idleThreshold = idleThreshold
    }

    /// Records one sample. Pass nil when nothing should be tracked (screen
    /// locked, system going to sleep).
    public func record(_ sample: ActivitySample?, at now: Date) throws {
        guard let sample, sample.idleSeconds < idleThreshold else {
            // Trim the idle tail: input stopped `idleSeconds` ago, but we kept
            // extending the span until the threshold tripped.
            if let current, let sample {
                let lastInput = now.addingTimeInterval(-sample.idleSeconds)
                if lastInput < current.end {
                    try store.setEnd(activityID: current.id, end: max(current.start, lastInput))
                }
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
            // A switch within the gap means the previous span lasted until now.
            if let current, now.timeIntervalSince(current.end) <= maxGap {
                try store.setEnd(activityID: current.id, end: now)
            }
            let id = try store.insertActivity(start: now, end: now, source: Source.window, sample: sample)
            current = (id, key, now, now)
        }
    }
}
