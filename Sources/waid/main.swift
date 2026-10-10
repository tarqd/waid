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
      waid report [RANGE] [--entries|--unlogged] [--by project|client|category|day]
                                         Observed activities (default), confirmed time entries with
                                         utilization, or activity not covered by any entry
                                         (RANGE: \(TimeRange.names.joined(separator: ", ")))
      waid timesheet [RANGE] [--client NAME]
                                         Confirmed entries as CSV, one row per day/project/category
      waid budgets                       Hours used vs budget per engagement
      waid start [PROJECT] [TITLE] [--category NAME]
                                         Start a timer (stops any running one). PROJECT is
                                         "Client / Project" or an internal project name
      waid stop                          Stop the running timer
      waid import [--full]               Import Claude Code sessions now
      waid status                        Show the current activity and timer
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

/// Every process that opens the store reports the zone it's in (ADR-0001).
func openStore() -> (Store, String) {
    let opened: (Store, String)
    do {
        let path = try Store.defaultPath()
        opened = (try Store(path: path), path)
    } catch {
        fail("can't open database: \(error)")
    }
    reportZone(to: opened.0)
    return opened
}

/// Adds a zone-history record if the machine's zone has changed since the
/// latest one. Re-reads the system zone, which Foundation otherwise caches for
/// the life of the process.
func reportZone(to store: Store) {
    NSTimeZone.resetSystemTimeZone()
    do { try store.recordZone(.current, now: Date()) } catch { log("recording time zone failed: \(error)") }
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
    let recorder = ActivityRecorder(store: store, maxGap: interval * 3)
    let ingestor = ClaudeCodeIngestor()
    func importAgents() {
        do { try ingestor.ingest(into: store) } catch { log("agent import failed: \(error)") }
    }
    func record(_ sample: ActivitySample?) {
        reportZone(to: store)
        do { try recorder.record(sample, at: Date()) } catch { log("recording failed: \(error)") }
    }
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                 NSWorkspace.sessionDidResignActiveNotification] {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in record(nil) }
    }
    RunLoop.main.add(Timer(timeInterval: interval, repeats: true) { _ in record(sampler.sample()) }, forMode: .common)
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
    guard let range = TimeRange.named(name) else { fail("unknown range \"\(name)\"\n\n\(usage)") }
    func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
    do {
        if args.contains("--entries") || args.contains("--unlogged") {
            let entries = args.contains("--entries")
            let rows = entries
                ? try store.entrySummary(in: range, groupBy: groupBy)
                : try store.unloggedSummary(in: range, groupBy: groupBy)
            guard !rows.isEmpty else { print("nothing \(entries ? "logged" : "unlogged") \(name)"); break }
            let width = max(12, rows.map(\.key.count).max() ?? 0)
            print(pad(byName, width) + "  time      " + (entries ? "billable" : ""))
            for row in rows {
                print(pad(row.key, width) + "  " + pad(formatMinutes(row.seconds), 10)
                      + (entries ? formatMinutes(row.billableSeconds) : ""))
            }
            if entries {
                let total = rows.reduce(0) { $0 + $1.seconds }, billable = rows.reduce(0) { $0 + $1.billableSeconds }
                print(pad("total", width) + "  " + pad(formatMinutes(total), 10) + formatMinutes(billable)
                      + (total > 0 ? "  (\(Int((billable / total * 100).rounded()))% utilization)" : ""))
            }
            break
        }
        let rows = try store.summary(in: range, groupBy: groupBy)
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
    guard let range = TimeRange.named(name) else { fail("unknown range \"\(name)\"\n\n\(usage)") }
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

case "db-path":
    print(openStore().1)

case "help", "--help", "-h":
    print(usage)

case "--version", "version":
    print(version)

default:
    fail("unknown command \"\(command)\"\n\n\(usage)")
}
