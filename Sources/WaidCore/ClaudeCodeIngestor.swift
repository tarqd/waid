import Foundation

/// Imports Claude Code sessions as agent time.
///
/// Claude Code writes one JSONL transcript per session under
/// `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Each session is split
/// into segments wherever the transcript goes quiet for longer than `splitGap`,
/// so a session left open overnight doesn't count as eight hours of work.
public struct ClaudeCodeIngestor {
    public static let source = Source.agent("claude-code")
    private static let lastRunKey = "ingest.claude-code.last_run"

    public var root: URL
    public var splitGap: TimeInterval

    public init(root: URL? = nil, splitGap: TimeInterval = 15 * 60) {
        self.root = root ?? Self.defaultRoot()
        self.splitGap = splitGap
    }

    public static func defaultRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    public struct Segment: Equatable {
        public var sessionID: String
        public var index: Int
        public var start: Date
        public var end: Date
        public var cwd: String?
        public var gitBranch: String?
        public var title: String?
    }

    public struct Report: Codable, Equatable {
        public var filesScanned = 0
        public var segmentsUpserted = 0
        public var filesFailed: [String] = []
    }

    /// Imports transcripts changed since the last run (or all, if `full`).
    @discardableResult
    public func ingest(into store: Store, full: Bool = false) throws -> Report {
        var report = Report()
        let startedAt = Date()
        let since = full ? nil : try store.value(forKey: Self.lastRunKey).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return report }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if let since,
               let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < since.addingTimeInterval(-60) {
                continue
            }
            report.filesScanned += 1
            do {
                let data = try Data(contentsOf: url)
                let segments = Self.segments(fromTranscript: data, splitGap: splitGap)
                try store.db.transaction {
                    for segment in segments {
                        var meta: [String: String] = ["session_id": segment.sessionID]
                        if let branch = segment.gitBranch { meta["git_branch"] = branch }
                        let metaJSON = (try? JSONEncoder().encode(meta)).flatMap { String(data: $0, encoding: .utf8) }
                        try store.upsertExternal(
                            source: Self.source, externalID: "\(segment.sessionID)#\(segment.index)",
                            start: segment.start, end: segment.end, title: segment.title, path: segment.cwd,
                            meta: metaJSON)
                    }
                }
                report.segmentsUpserted += segments.count
            } catch {
                report.filesFailed.append("\(url.path): \(error)")
            }
        }
        try store.setValue(String(startedAt.timeIntervalSince1970), forKey: Self.lastRunKey)
        return report
    }

    public static func segments(fromTranscript data: Data, splitGap: TimeInterval) -> [Segment] {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        var sessionID: String?
        var summary: String?
        var firstPrompt: String?
        var events: [(date: Date, cwd: String?, branch: String?)] = []

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if object["type"] as? String == "summary" {
                summary = summary ?? (object["summary"] as? String)
                continue
            }
            guard let stamp = object["timestamp"] as? String,
                  let date = fractional.date(from: stamp) ?? plain.date(from: stamp)
            else { continue }
            sessionID = sessionID ?? (object["sessionId"] as? String)
            events.append((date, object["cwd"] as? String, object["gitBranch"] as? String))
            if firstPrompt == nil, object["type"] as? String == "user", object["isMeta"] as? Bool != true,
               let message = object["message"] as? [String: Any],
               let text = promptText(message["content"]) {
                firstPrompt = text
            }
        }
        guard let sessionID, !events.isEmpty else { return [] }
        events.sort { $0.date < $1.date }

        let title = (summary ?? firstPrompt).map { truncate($0, to: 120) }
        var segments: [Segment] = []
        for event in events {
            if var last = segments.last, event.date.timeIntervalSince(last.end) <= splitGap {
                last.end = event.date
                last.cwd = last.cwd ?? event.cwd
                last.gitBranch = last.gitBranch ?? event.branch
                segments[segments.count - 1] = last
            } else {
                segments.append(Segment(
                    sessionID: sessionID, index: segments.count, start: event.date, end: event.date,
                    cwd: event.cwd, gitBranch: event.branch, title: title))
            }
        }
        return segments
    }

    /// The first human-typed prompt; skips tool results and command wrappers.
    private static func promptText(_ content: Any?) -> String? {
        var text: String?
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, !trimmed.hasPrefix("<")
        else { return nil }
        return trimmed
    }

    private static func truncate(_ s: String, to length: Int) -> String {
        let single = s.replacingOccurrences(of: "\n", with: " ")
        return single.count <= length ? single : String(single.prefix(length - 1)) + "…"
    }
}
