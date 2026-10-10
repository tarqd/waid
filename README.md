# waid

**What am I doing?** A local-first, agent-native alternative to [Timing](https://timingapp.com) for macOS.

- **No cloud, no account, no subscription.** Everything lives in one SQLite file on your Mac.
- **MCP server built in.** Ask any MCP client ("what did I work on last week?", "categorize my uncategorized time", "fill in my timesheet") and it queries and edits your data directly.
- **Agent work is time too.** Claude Code sessions are imported automatically, and any agent can log its own work with `record_agent_work`.
- **Built for professional services.** Client engagements (with hours budgets) and internal projects, plus categories like presales, implementation and meetings as a separate dimension. Budget burn, utilization and CSV timesheets are built in.
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
| `get_status` | Current activity, running timer, Unlogged time today (and how much is billable), idle threshold |
| `set_idle_threshold` | Read or change the idle threshold (seconds, 0 to 86400); changing it re-reads every past day |
| `query_activity` | Observed activities in a range, filterable by project/source/text |
| `summarize` | Summary: claimed time from time entries, with billable minutes and utilization, by client / project / category / day |
| `evidence` | Evidence for claiming time, never claimed time: `kind=activities` (observed minutes per source, never summed across sources; also by app / source) or `kind=unlogged` (work a suggestion would offer to claim that no confirmed entry covers, with billable minutes) |
| `top_uncategorized` | Biggest uncategorized chunks, with example titles, for writing rules |
| `assign_activity`, `hide_activity` | Pin activities to a project and/or category; hide private ones |
| `list_clients`, `create_client` | Clients and their domains (acme.com attributes matching URLs) |
| `list_projects`, `create_project`, `update_project` | Engagements ("Acme / Phase 2": status, budget, dates) and internal projects |
| `list_categories`, `create_category` | Kinds of work; a category can be never-billable (presales) |
| `create_rule`, `delete_rule` | Retroactive rules setting project and/or category (contains / equals / prefix / regex) |
| `query_time_entries` | Entries in a range, by project / status / text |
| `create_time_entry`, `update_time_entry`, `delete_time_entry` | Edit entries; overlaps are rejected |
| `suggest_time_entries` | Draft entries from categorized activities, with the titles and apps that contributed most to each |
| `confirm_time_entries` | Turn drafts into real entries |
| `start_timer`, `stop_timer` | Running entries |
| `budget_status` | Hours used vs budget per engagement |
| `timesheet` | One row per day × project × category with billing notes; JSON or CSV |
| `record_agent_work` | Any agent logs its own work as an activity (idempotent by `external_id`) |
| `import_agent_sessions` | Refresh Claude Code sessions now |

Entries an agent writes record it as the author (`agent:claude-code`), so you can see and undo them.

Ranges are local dates, matched against the date stored on each activity and entry where it happened (weeks start Monday); timestamps with a time of day are exact instants. A date range is echoed back as `start` and `end` dates, both inclusive.

**Breaking change:** `summarize` used to default to activity totals and took a `kind`. It now reports time entries only (a Summary); activity totals and Unlogged time moved to the `evidence` tool. Likewise `waid report` now shows the Summary by default, with `--evidence` and `--unlogged` for the others (`--entries` is gone). `suggest_time_entries` returns each draft's top titles and apps as `contributors` (formerly `evidence`), since Evidence now names activity totals.

## CLI

```
waid report [today|yesterday|this_week|last_week|last_7_days|this_month|last_30_days] [--evidence|--unlogged] [--by client|project|category|day]
waid timesheet [RANGE] [--client NAME]      # CSV
waid budgets
waid start ["Client / Project" | internal-project] [TITLE] [--category NAME]
waid stop
waid status
waid settings idle-threshold [SECONDS]   # print, or set (0 to 86400)
waid import [--full]
waid db-path
```

## License

GPL-3.0
