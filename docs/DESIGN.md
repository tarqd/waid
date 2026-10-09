# waid design

## Goal

A Timing-class automatic time tracker for macOS that is **local-only** (no cloud service, no account, no subscription) and **agent-native** (agents can read, categorize and add to your time data over MCP, and agent work is tracked as time).

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | macOS only for v1 | Capture quality is the product. macOS has a coherent API for it (NSWorkspace, Accessibility, AppleScript); Linux/Windows can come later behind the same `ActivitySample` boundary. |
| 2 | Swift + SwiftUI, SwiftPM, zero third-party dependencies | Native APIs, a native app later, and nothing to audit or update. SQLite comes from the system. |
| 3 | One SQLite file (WAL mode) is the only state | The daemon writes, and the MCP server and future app read and write concurrently. Backups and sync are "copy the file". |
| 4 | Headless daemon + stdio MCP server first, GUI second | Proves the hard part (capture) and the differentiator (MCP) before investing in UI. |
| 5 | Samples are merged into spans as they're written | Storage stays small (one row per contiguous activity, not one per 5 s). |
| 6 | Rules are evaluated at query time, assignments win | Adding a rule recategorizes history instantly, which makes agent-proposed rules cheap to try and to undo. |
| 7 | Sources (`window`, `timer`, `manual`, `agent:*`) overlap and are reported separately | An agent working for 2 h while you're in Slack is real information; summing it with your window time would be a lie. |
| 8 | LLM categorization happens through MCP, not inside waid | The user's own agent (Claude Code, Claude Desktop, …) calls `top_uncategorized` → `create_rule`. waid never stores an API key or makes a network call. A built-in local model could be added later as an optional feature. |
| 9 | Hand-rolled MCP (stdio, protocol 2025-06-18, tools only) | About 200 lines, no dependency. Switch to the official Swift SDK if we need resources, prompts or HTTP transport. |

## Architecture

```
            ┌──────────── waid daemon (launchd) ────────────┐
NSWorkspace │ MacActivitySampler ─► ActivityRecorder ─┐     │
AX / AS     │                                         ▼     │
            │ ClaudeCodeIngestor (every 5 min) ─►  Store ◄──┼── waid mcp (stdio) ◄── Claude Code / Desktop / any MCP client
~/.claude/  │                                    (SQLite)   │
            └───────────────────────────────────────▲───────┘
                                                    └────────── SwiftUI app (next)
```

- `WaidCore`: `Database` (SQLite wrapper), `Store` (schema, queries, summaries), `ActivityRecorder` (merges samples into spans, trims idle time), `RuleEngine`, `TimeRange`, `ClaudeCodeIngestor`.
- `WaidCapture`: `MacActivitySampler`, the only macOS-specific code.
- `WaidMCP`: `MCPServer` (JSON-RPC over stdio) and `WaidTools` (the tool surface).
- `waid`: the CLI (`daemon`, `mcp`, `report`, `import`, `status`).

### Data model

- `activities(start_ts, end_ts, source, bundle_id, app_name, title, url, path, external_id, project_id, note, meta)`. `end_ts` is NULL only for a running timer. `(source, external_id)` is unique so importers are idempotent.
- `projects(name, color, archived)` and `rules(project_id, field, op, pattern, priority)`.
- `kv` for bookkeeping such as the importer's last run.

### Capture details

- The front app is sampled every 5 s. A change of app, title, URL or document starts a new span, and the previous span is closed at the moment of the switch.
- After 3 min idle, the span is trimmed back to the last input. Sleep, screen lock and gaps longer than 3× the interval close the span.
- Claude Code transcripts (`~/.claude/projects/**/*.jsonl`) become one span per active segment. Segments split on gaps over 15 min, and spans are titled from the session summary or first prompt, with the working directory stored as `path`.

## Roadmap

**Next: make the daemon trustworthy on a real Mac**
- [ ] Dogfood for a week and tune the interval, idle threshold and sampling cost.
- [ ] Privacy controls: excluded apps/URLs, private browsing detection, a "pause tracking" switch, title redaction.
- [ ] Firefox URL capture (no AppleScript; needs AX on the URL bar or an extension).
- [ ] Signed and notarized build so the Accessibility permission sticks across updates.

**SwiftUI app**
- [ ] A menu bar item with the current activity, timer, pause control and today's total.
- [ ] A day timeline that lets you select spans to assign or split, with a rule editor.
- [ ] Reports and CSV/JSON export.
- [ ] The app embeds the daemon (an `SMAppService` login item) instead of a hand-installed launchd plist.

**Agents**
- [ ] Generic importers: Codex CLI, Cursor, Aider, and git commits as time anchors.
- [ ] MCP prompts: "categorize my week", "draft timesheet for client X".
- [ ] Optional HTTP MCP transport on localhost, for clients that can't spawn processes.
- [ ] Optional on-device categorization model, for people who don't run an agent.

**Later**
- [ ] Sync between your own Macs through a folder you control (iCloud Drive or Syncthing), merging change logs per device.
- [ ] Linux/Windows capture backends.
