# waid

**What am I doing?** A local-first, agent-native alternative to [Timing](https://timingapp.com) for macOS.

- **No cloud, no account, no subscription.** Everything lives in one SQLite file on your Mac.
- **MCP server built in.** Ask any MCP client ("what did I work on last week?", "categorize my uncategorized time", "fill in my timesheet") and it queries and edits your data directly.
- **Agent work is time too.** Claude Code sessions are imported automatically, and any agent can log its own work with `record_agent_work`.
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
| `get_status` | Current activity, running timer |
| `query_activity` | Spans in a range, filterable by project/source/text |
| `summarize` | Minutes per project / app / source / day, broken out by source |
| `top_uncategorized` | Biggest uncategorized chunks, with example titles, for writing rules |
| `list_projects`, `create_project` | Projects and their rules |
| `create_rule`, `delete_rule` | Retroactive categorization rules (contains / equals / prefix / regex) |
| `assign_activity` | Pin spans to a project, overriding rules |
| `start_timer`, `stop_timer`, `add_time_entry` | Manual time |
| `record_agent_work` | Any agent logs its own work (idempotent by `external_id`) |
| `import_agent_sessions` | Refresh Claude Code sessions now |

## CLI

```
waid report [today|yesterday|this_week|last_week|last_7_days|this_month|last_30_days]
waid status
waid import [--full]
waid db-path
```

## License

GPL-3.0
