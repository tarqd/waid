import Foundation

/// `waid settings ...`: reads or changes a stored setting. Kept out of the
/// executable so its parsing and validation can be tested.
public enum SettingsCommand {
    public static let usage = "usage: waid settings idle-threshold [SECONDS]  (0 to 86400; omit SECONDS to print the current value)"

    public struct UsageError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Runs the command with the arguments after `settings` and returns what
    /// to print. Throws `UsageError` for malformed arguments and
    /// `StoreError.invalid` for an out-of-range value.
    public static func run(_ args: [String], store: Store) throws -> String {
        guard let setting = args.first else { throw UsageError(description: usage) }
        guard setting == "idle-threshold" else {
            throw UsageError(description: "unknown setting \"\(setting)\"\n\(usage)")
        }
        switch args.count {
        case 1:
            return format(try store.idleThreshold())
        case 2:
            guard let seconds = Int(args[1]) else {
                throw UsageError(description: "the idle threshold is a whole number of seconds, not \"\(args[1])\"\n\(usage)")
            }
            try store.setIdleThreshold(TimeInterval(seconds))
            return "idle threshold set to \(format(try store.idleThreshold())) seconds"
        default:
            throw UsageError(description: usage)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        seconds.rounded() == seconds ? String(Int(seconds)) : String(seconds)
    }
}
