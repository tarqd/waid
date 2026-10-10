import Foundation
import WaidCore
import WaidMCP
#if os(macOS)
import AppKit
import WaidCapture
#endif

let version = "0.1.0"

let usage = """
    waid \(version): what am I doing? A local time tracker with an MCP server.

    USAGE:
      waid daemon [--interval SECONDS]   Track the frontmost app/window (macOS) and import agent sessions
      waid mcp                           Run the MCP server on stdio
      waid report [RANGE] [--evidence|--unlogged] [--by project|client|category|day]
                                         Summary of confirmed time entries with billable time and
                                         utilization (default); --evidence shows observed activity per
                                         source (also --by app|source); --unlogged shows work not yet
                                         claimed, with billable time (RANGE: \(TimeRange.names.joined(separator: ", "));
                                         ranges are local dates where you were, weeks start Monday)
      waid timesheet [RANGE] [--client NAME]
                                         Confirmed entries as CSV, one row per day/project/category
      waid budgets                       Hours used vs budget per engagement
      waid start [PROJECT] [TITLE] [--category NAME]
                                         Start a timer (stops any running one). PROJECT is
                                         "Client / Project" or an internal project name
      waid stop                          Stop the running timer
      waid import [--full]               Import Claude Code sessions now
      waid status                        Show the current activity, timer and idle threshold
      waid settings idle-threshold [SECONDS]
                                         Print the idle threshold, or set it (0 to 86400): the longest
                                         pause in input that still counts as present. Changing it
                                         re-reads every past day
      waid db-path                       Print the database location

    The database lives at $WAID_DB if set.
    """

func log(_ message: String) {
    FileHandle.standardError.write(Data("waid: \(message)\n".utf8))
}

func fail(_ message: String) -> Never {
    log(message)
    exit(1)
}

func openStore() -> (Store, String) {
    do {
        let path = try Store.defaultPath()
        return (try Store(path: path), path)
    } catch {
        fail("can't open database: \(error)")
    }
}

/// The local dates a named range covers, counted from today where you are
/// now: the zone of the latest observation, else this process's zone.
func namedRange(_ name: String, store: Store) -> ReportRange? {
    let now = Date()
    let zone = ((try? store.calendar(at: now)) ?? .current).timeZone
    return TimeRange.named(name, today: LocalDate(now, in: zone)).map(ReportRange.localDates)
}

var args = Array(CommandLine.arguments.dropFirst())

/// Removes `--name VALUE` from args and returns VALUE.
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func formatMinutes(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
}

let command = args.isEmpty ? "help" : args.removeFirst()

switch command {
case "mcp":
    let (store, _) = openStore()
    let server = MCPServer(name: "waid", version: version, instructions: WaidTools.instructions,
                           tools: WaidTools.make(store: store))
    server.run()

case "daemon":
    var interval: TimeInterval = 5
    if let i = args.firstIndex(of: "--interval"), i + 1 < args.count, let v = Double(args[i + 1]), v >= 1 {
        interval = v
    }
    let (store, path) = openStore()
    #if os(macOS)
    if !MacActivitySampler.accessibilityTrusted(prompt: true) {
        log("Accessibility access not granted; tracking apps only (no window titles). Grant it in System Settings > Privacy & Security > Accessibility.")
    }
    let sampler = MacActivitySampler()
    let recorder = ActivityRecorder(store: store, interval: interval)
    let ingestor = ClaudeCodeIngestor()
    func importAgents() {
        do { try ingestor.ingest(into: store) } catch { log("agent import failed: \(error)") }
    }
    func record(_ signal: ActivityRecorder.Signal) {
        // Re-read the system zone, which Foundation otherwise caches for the life of the process.
        NSTimeZone.resetSystemTimeZone()
        do { try recorder.record(signal, at: Date(), zone: .current) } catch { log("recording failed: \(error)") }
    }
    // Waking fires while the lock screen is still up, so once the screen is
    // locked only an unlock or a return to this session ends it.
    var screenLocked = false
    let workspace = NSWorkspace.shared.notificationCenter
    let distributed = DistributedNotificationCenter.default()
    // (center, name, signal, whether it locks (true) or unlocks (false) the screen)
    let signals: [(NotificationCenter, Notification.Name, ActivityRecorder.Signal, Bool?)] = [
        (workspace, NSWorkspace.willSleepNotification, .sleep, nil),
        (workspace, NSWorkspace.screensDidSleepNotification, .lock, nil),
        (workspace, NSWorkspace.sessionDidResignActiveNotification, .lock, true),
        (distributed, Notification.Name("com.apple.screenIsLocked"), .lock, true),
        (workspace, NSWorkspace.didWakeNotification, .wake, nil),
        (workspace, NSWorkspace.screensDidWakeNotification, .unlock, nil),
        (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .unlock, false),
        (distributed, Notification.Name("com.apple.screenIsUnlocked"), .unlock, false),
    ]
    for (center, name, signal, screenLock) in signals {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
            if let screenLock {
                screenLocked = screenLock
            } else if screenLocked && (signal == .wake || signal == .unlock) {
                return
            }
            record(signal)
        }
    }
    RunLoop.main.add(Timer(timeInterval: interval, repeats: true) { _ in
        // No frontmost app: nothing to sample, so open observations stop
        // extending and the heartbeat window closes them.
        if let sample = sampler.sample() { record(.sample(sample)) }
    }, forMode: .common)
    RunLoop.main.add(Timer(timeInterval: 300, repeats: true) { _ in importAgents() }, forMode: .common)
    importAgents()
    log("tracking every \(Int(interval))s into \(path)")
    RunLoop.main.run()
    #else
    _ = (store, path, interval)
    fail("window tracking is only implemented on macOS; `waid import` and `waid mcp` work here")
    #endif

case "import":
    let (store, _) = openStore()
    do {
        let report = try ClaudeCodeIngestor().ingest(into: store, full: args.contains("--full"))
        print("scanned \(report.filesScanned) transcript(s), upserted \(report.segmentsUpserted) segment(s)")
        for failure in report.filesFailed { log("failed: \(failure)") }
    } catch {
        fail("import failed: \(error)")
    }

case "report":
    let (store, _) = openStore()
    let byName = option("--by") ?? "project"
    guard let groupBy = Store.GroupBy(rawValue: byName) else { fail("unknown --by \"\(byName)\"\n\n\(usage)") }
    let name = args.first { !$0.hasPrefix("--") } ?? "today"
    guard let range = namedRange(name, store: store) else { fail("unknown range \"\(name)\"\n\n\(usage)") }
    if args.contains("--unlogged") && args.contains("--evidence") {
        fail("--unlogged and --evidence are different reports; pass one\n\n\(usage)")
    }
    func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
    /// A Summary or Unlogged time as a table: one row per group, then the total.
    func printTotals(_ totals: Store.TimeTotals, column: String, totalSuffix: String = "") {
        let width = max(12, totals.groups.map(\.key.count).max() ?? 0)
        print(pad(byName, width) + "  " + pad(column, 10) + "billable")
        for group in totals.groups {
            print(pad(group.key, width) + "  " + pad(formatMinutes(group.seconds), 10) + formatMinutes(group.billableSeconds))
        }
        print(pad("total", width) + "  " + pad(formatMinutes(totals.seconds), 10) + formatMinutes(totals.billableSeconds) + totalSuffix)
    }
    do {
        if args.contains("--unlogged") {
            let unlogged = try store.unloggedTime(in: range, groupBy: groupBy)
            guard !unlogged.groups.isEmpty else { print("nothing unlogged \(name)"); break }
            printTotals(unlogged, column: "unlogged")
            break
        }
        guard args.contains("--evidence") else {
            let summary = try store.summary(in: range, groupBy: groupBy)
            guard !summary.groups.isEmpty else { print("nothing logged \(name)"); break }
            printTotals(summary, column: "time",
                        totalSuffix: summary.utilization.map { "  (\(Int(($0 * 100).rounded()))% utilization)" } ?? "")
            break
        }
        let rows = try store.evidence(in: range, groupBy: groupBy)
        let sources = Set(rows.flatMap { $0.secondsBySource.keys }).sorted()
        guard !rows.isEmpty else { print("nothing tracked \(name)"); break }
        let width = max(12, rows.map(\.key.count).max() ?? 0)
        print(pad(byName, width) + sources.map { "  " + pad($0, max(10, $0.count)) }.joined())
        for row in rows {
            print(pad(row.key, width) + sources.map {
                "  " + pad(row.secondsBySource[$0].map(formatMinutes) ?? "-", max(10, $0.count))
            }.joined())
        }
    } catch {
        fail("report failed: \(error)")
    }

case "timesheet":
    let (store, _) = openStore()
    let clientName = option("--client")
    let name = args.first ?? "this_week"
    guard let range = namedRange(name, store: store) else { fail("unknown range \"\(name)\"\n\n\(usage)") }
    do {
        var filter = Store.EntryFilter()
        filter.clientID = try clientName.map { try store.requireClient(named: $0).id }
        print(Store.csv(try store.timesheet(in: range, filter: filter)), terminator: "")
    } catch {
        fail("timesheet failed: \(error)")
    }

case "budgets":
    let (store, _) = openStore()
    do {
        let rows = try store.budgetStatus()
        guard !rows.isEmpty else { print("no projects with a budget"); break }
        func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
        let width = max(12, rows.map(\.project.count).max() ?? 0)
        print(pad("project", width) + "  used      budget    burn")
        for row in rows {
            let budget = row.budgetHours.map { String(format: "%.1fh", $0) } ?? "-"
            let burn = row.burn.map { "\(Int(($0 * 100).rounded()))%" } ?? "-"
            print(pad(row.project, width) + "  " + pad(String(format: "%.1fh", row.usedHours), 10) + pad(budget, 10) + burn)
        }
    } catch {
        fail("budgets failed: \(error)")
    }

case "start":
    let (store, _) = openStore()
    let categoryName = option("--category")
    do {
        let project = try args.first.map { try store.ensureProject($0).id }
        let category = try categoryName.map { try store.requireCategory(named: $0).id }
        let title = args.count > 1 ? args.dropFirst().joined(separator: " ") : nil
        let result = try store.startTimer(projectID: project, categoryID: category, title: title)
        if let stopped = result.stopped {
            print("stopped \(stopped.project ?? "timer") after \(formatMinutes(stopped.duration()))")
        }
        print("started " + [result.started.project, result.started.category].compactMap { $0 }.joined(separator: " · "))
    } catch {
        fail("can't start timer: \(error)")
    }

case "stop":
    let (store, _) = openStore()
    do {
        guard let stopped = try store.stopTimer() else { print("no timer running"); break }
        print("stopped \(stopped.project ?? "timer") after \(formatMinutes(stopped.duration()))")
    } catch {
        fail("can't stop timer: \(error)")
    }

case "status":
    let (store, _) = openStore()
    let tools = WaidTools.make(store: store)
    let server = MCPServer(name: "waid", version: version, tools: tools)
    // Reuse the MCP tool so CLI and agents see the same thing.
    if let response = server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_status"}}"#),
       let value = try? JSONDecoder().decode(JSONValue.self, from: Data(response.utf8)),
       case .array(let content)? = value["result"]?["content"],
       let text = content.first?["text"]?.stringValue {
        print(text)
    }

case "settings":
    let (store, _) = openStore()
    do {
        print(try SettingsCommand.run(args, store: store))
    } catch {
        fail("\(error)")
    }

case "db-path":
    print(openStore().1)

case "help", "--help", "-h":
    print(usage)

case "--version", "version":
    print(version)

default:
    fail("unknown command \"\(command)\"\n\n\(usage)")
}
