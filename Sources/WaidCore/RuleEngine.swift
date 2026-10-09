import Foundation

/// Resolves the project and category for an activity from user rules, and
/// the client from client domains. Rules are evaluated at query time, so
/// adding or editing one recategorizes history retroactively.
///
/// Project and category are resolved independently: the first matching rule
/// that sets a project decides the project, and the first matching rule that
/// sets a category decides the category.
public struct RuleEngine {
    private let rules: [(Rule, NSRegularExpression?)]
    private let domains: [(domain: String, client: Client)]

    /// `rules` should already be in evaluation order (priority desc, id asc).
    public init(rules: [Rule], clients: [Client] = []) {
        self.rules = rules.map { rule in
            let regex = rule.op == .regex
                ? try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) : nil
            return (rule, regex)
        }
        // Longest domain first, so eu.acme.com beats acme.com.
        domains = clients.flatMap { c in c.domains.map { ($0, c) } }.sorted { $0.domain.count > $1.domain.count }
    }

    public func projectRule(for activity: Activity) -> Rule? {
        firstMatch(for: activity) { $0.projectID != nil }
    }

    public func categoryRule(for activity: Activity) -> Rule? {
        firstMatch(for: activity) { $0.categoryID != nil }
    }

    /// The client whose domain matches the activity's URL host.
    public func client(for activity: Activity) -> Client? {
        guard let host = activity.url.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return nil }
        return domains.first { host == $0.domain || host.hasSuffix("." + $0.domain) }?.client
    }

    private func firstMatch(for activity: Activity, where include: (Rule) -> Bool) -> Rule? {
        rules.first { rule, regex in
            guard include(rule), let value = Self.value(of: rule.field, in: activity) else { return false }
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
