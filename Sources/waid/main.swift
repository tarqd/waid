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
      waid report [RANGE]                Time per project (RANGE: \(TimeRange.names.joined(separator: ", ")))
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

func openStore() -> (Store, String) {
    do {
        let path = try Store.defaultPath()
        return (try Store(path: path), path)
    } catch {
        fail("can't open database: \(error)")
    }
}

func formatMinutes(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded())
    return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
}

var args = Array(CommandLine.arguments.dropFirst())
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
    let name = args.first ?? "today"
    guard let range = TimeRange.named(name) else { fail("unknown range \"\(name)\"\n\n\(usage)") }
    do {
        let rows = try store.summary(in: range, groupBy: .project)
        let sources = Set(rows.flatMap { $0.secondsBySource.keys }).sorted()
        guard !rows.isEmpty else { print("nothing tracked \(name)"); break }
        func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
        let width = max(12, rows.map(\.key.count).max() ?? 0)
        print(pad("project", width) + sources.map { "  " + pad($0, max(10, $0.count)) }.joined())
        for row in rows {
            print(pad(row.key, width) + sources.map {
                "  " + pad(row.secondsBySource[$0].map(formatMinutes) ?? "-", max(10, $0.count))
            }.joined())
        }
    } catch {
        fail("report failed: \(error)")
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
