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
| 7 | Activity sources (`window`, `agent:*`, later `browser:*`/`editor:*`) overlap and are reported separately | An agent working for 2 h while you're in Slack is real information; summing it with your window time would be a lie. |
| 10 | **Activities** (observed) and **time entries** (claimed) are separate tables, as in Timing | Activities are automatic, fine-grained evidence you categorize but don't edit. Entries are intentional, coarse, editable, and what reports and billing use. Mixing them makes both worse. |
| 11 | Time entries never overlap | Entries are one timeline of what you claim; overlap is almost always a mistake. Parallel agent work stays an activity. |
| 12 | Entries link to activities by time overlap, not a join table | Resizing an entry automatically changes its evidence; there's nothing to keep in sync. |
| 13 | Drafts are only created on demand (`suggest_time_entries`), and agent time is excluded unless asked | Background drafts pile up unreviewed; agent time isn't automatically the user's to claim. A per-project "auto-confirm agent work" setting can come later. |
| 14 | Entries record their `author` (`user` or `agent:<MCP client name>`) and `origin` (timer, manual, from_activities, suggested) | You can always see, filter and undo what an agent wrote. |
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

```
projects      id, name (unique), parent_id, color, archived      -- tree; displayed as "Clients / Acme"
rules         id, project_id, field, op, pattern, priority       -- categorize activities at query time

activities    id, source, start_ts, end_ts,                      -- OBSERVED: append-only evidence
              bundle_id, app_name, title, url, path,
              external_id,     -- (source, external_id) unique, so importers are idempotent
              project_id,      -- manual override; otherwise rules decide
              hidden, note, meta

time_entries  id, start_ts, end_ts (NULL = running timer),       -- CLAIMED: editable, never overlapping
              project_id, title, notes, tags, billable,
              origin (timer | manual | from_activities | suggested),
              author (user | agent:<client>),
              status (draft | confirmed)

kv            key, value                                         -- bookkeeping, e.g. importer last run
```

Three views fall out of this:
- **Activities by project**: where your time actually went.
- **Confirmed entries by project**: what you report and bill.
- **Unlogged**: categorized activity that no confirmed entry covers ("3 h on waid you haven't logged").

### Suggesting entries

`suggest_time_entries` cuts the range into 1-minute buckets and labels each with the project holding most of its active time. Buckets that are idle, uncategorized or contested get no label. Same-project runs within 5 minutes are merged, absorbing a short interruption between them (Xcode, a quick Slack check, Xcode → one block). Time already covered by entries is cut out, blocks under 10 minutes are dropped, and each draft is titled from its biggest window titles or agent session summaries. Re-running replaces earlier suggestions in the range but never touches confirmed entries or drafts the user made.

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
- [ ] A day timeline with activities and entries side by side: drag over activities to create an entry, review and confirm drafts, and a rule editor.
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
