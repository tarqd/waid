# waid

**What am I doing?** A local-first, agent-native alternative to [Timing](https://timingapp.com) for macOS.

- **No cloud, no account, no subscription.** Everything lives in one SQLite file on your Mac.
- **MCP server built in.** Ask any MCP client ("what did I work on last week?", "categorize my uncategorized time", "fill in my timesheet") and it queries and edits your data directly.
- **Agent work is time too.** Claude Code sessions are imported automatically, and any agent can log its own work with `record_agent_work`.
- **Activities in, time entries out.** Like Timing, waid separates what it *observed* (activities) from what you *claim* (time entries, the numbers you report and bill). Agents can draft entries from your day, and you confirm them.
- **Your agent is the auto-categorizer.** Rules are retroactive, so an agent can look at `top_uncategorized` and write rules for you, with no API key stored in waid.

Status: early. Headless daemon + MCP server work; the SwiftUI app is next. See [docs/DESIGN.md](docs/DESIGN.md).

## Build

```sh
swift build -c release
cp .build/release/waid /usr/local/bin/   # or anywhere on PATH
```

Requires macOS 14+ for tracking. The core, importer and MCP server also build and test on Linux (`swift test`).

## Run the tracker

```sh
waid daemon            # samples the frontmost app every 5s
```

On first run macOS asks for **Accessibility** access (window titles, document paths) and, per browser, **Automation** access (tab URLs). Without them waid tracks apps only.

To start at login, edit the binary path in [`contrib/io.tarq.waid.plist`](contrib/io.tarq.waid.plist), then:

```sh
cp contrib/io.tarq.waid.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/io.tarq.waid.plist
```

## Connect an agent

```sh
claude mcp add waid -- waid mcp                    # Claude Code
```

Or in any MCP client config:

```json
{ "mcpServers": { "waid": { "command": "waid", "args": ["mcp"] } } }
```

| Tool | What it does |
|---|---|
| `get_status` | Current activity, running timer, minutes unlogged today |
| `query_activity` | Observed activities in a range, filterable by project/source/text |
| `summarize` | `kind=activities` (minutes per source), `entries` (confirmed + billable) or `unlogged` (activity no entry covers), by project / app / source / day |
| `top_uncategorized` | Biggest uncategorized chunks, with example titles, for writing rules |
| `assign_activity`, `hide_activity` | Pin activities to a project; hide private ones |
| `list_projects`, `create_project` | Projects (nestable) and their rules |
| `create_rule`, `delete_rule` | Retroactive categorization rules (contains / equals / prefix / regex) |
| `query_time_entries` | Entries in a range, by project / status / text |
| `create_time_entry`, `update_time_entry`, `delete_time_entry` | Edit entries; overlaps are rejected |
| `suggest_time_entries` | Draft entries from categorized activities, with the evidence behind each |
| `confirm_time_entries` | Turn drafts into real entries |
| `start_timer`, `stop_timer` | Running entries |
| `record_agent_work` | Any agent logs its own work as an activity (idempotent by `external_id`) |
| `import_agent_sessions` | Refresh Claude Code sessions now |

Entries an agent writes record it as the author (`agent:claude-code`), so you can see and undo them.

## CLI

```
waid report [today|yesterday|this_week|last_week|last_7_days|this_month|last_30_days] [--entries|--unlogged]
waid start [PROJECT] [TITLE]
waid stop
waid status
waid import [--full]
waid db-path
```

## License

GPL-3.0
