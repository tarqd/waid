import Foundation

/// Resolves the project for a span from user rules. Rules are evaluated at
/// query time, so adding or editing a rule recategorizes history retroactively.
public struct RuleEngine {
    private let rules: [(Rule, NSRegularExpression?)]

    /// `rules` should already be in evaluation order (priority desc, id asc).
    public init(rules: [Rule]) {
        self.rules = rules.map { rule in
            let regex = rule.op == .regex
                ? try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) : nil
            return (rule, regex)
        }
    }

    public func projectID(for activity: Activity) -> Int64? {
        firstMatch(for: activity)?.projectID
    }

    public func firstMatch(for activity: Activity) -> Rule? {
        rules.first { rule, regex in
            guard let value = Self.value(of: rule.field, in: activity) else { return false }
            switch rule.op {
            case .contains: return value.localizedCaseInsensitiveContains(rule.pattern)
            case .equals: return value.caseInsensitiveCompare(rule.pattern) == .orderedSame
            case .prefix: return value.lowercased().hasPrefix(rule.pattern.lowercased())
            case .regex:
                guard let regex else { return false }
                return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
            }
        }?.0
    }

    private static func value(of field: RuleField, in activity: Activity) -> String? {
        switch field {
        case .bundleID: return activity.bundleID
        case .appName: return activity.appName
        case .title: return activity.title
        case .url: return activity.url
        case .path: return activity.path
        case .source: return activity.source
        }
    }
}
