# waid design

## Goal

A Timing-class automatic time tracker for macOS that is **local-only** (no cloud service, no account, no subscription) and **agent-native** (agents can read, categorize and add to your time data over MCP, and agent work is tracked as time). It's built around how professional-services people work: client engagements with budgets, internal projects, and time split by kind of work (presales, implementation, meetings).

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | macOS only for v1 | Capture quality is the product. macOS has a coherent API for it (NSWorkspace, Accessibility, AppleScript); Linux/Windows can come later behind the same `ActivitySample` boundary. |
| 2 | Swift + SwiftUI, SwiftPM, zero third-party dependencies | Native APIs, a native app later, and nothing to audit or update. SQLite comes from the system. |
| 3 | One SQLite file (WAL mode) is the only state | The daemon writes, and the MCP server and future app read and write concurrently. Backups and sync are "copy the file". |
| 4 | Headless daemon + stdio MCP server first, GUI second | Proves the hard part (capture) and the differentiator (MCP) before investing in UI. |
| 5 | Samples are merged into untrimmed observations as they're written; presence is derived when you ask | Storage stays small (one row per contiguous stretch of a stream, not one per 5 s), and nothing is thrown away at capture: the idle threshold is a setting read at query time, so changing it re-reads every past day with no data rewrite, and away time stays answerable. |
| 6 | Rules are evaluated at query time, assignments win | Adding a rule recategorizes history instantly, which makes agent-proposed rules cheap to try and to undo. |
| 7 | Activity sources (`window`, `agent:*`, later `browser:*`/`editor:*`) overlap and are reported separately | An agent working for 2 h while you're in Slack is real information; summing it with your window time would be a lie. |
| 8 | LLM categorization happens through MCP, not inside waid | The user's own agent (Claude Code, Claude Desktop, …) calls `top_uncategorized` → `create_rule`. waid never stores an API key or makes a network call. A built-in local model could be added later as an optional feature. |
| 9 | Hand-rolled MCP (stdio, protocol 2025-06-18, tools only) | About 200 lines, no dependency. Switch to the official Swift SDK if we need resources, prompts or HTTP transport. |
| 10 | **Activities** (observed) and **time entries** (claimed) are separate tables, as in Timing | Activities are automatic, fine-grained evidence you categorize but don't edit. Entries are intentional, coarse, editable, and what reports and billing use. Mixing them makes both worse. |
| 11 | Time entries never overlap | Entries are one timeline of what you claim; overlap is almost always a mistake. Parallel agent work stays an activity. |
| 12 | Entries link to activities by time overlap, not a join table | Resizing an entry automatically changes its evidence; there's nothing to keep in sync. |
| 13 | Drafts are only created on demand (`suggest_time_entries`), and agent time is excluded unless asked | Background drafts pile up unreviewed; agent time isn't automatically the user's to claim. A per-project "auto-confirm agent work" setting can come later. |
| 14 | Entries record their `author` (`user` or `agent:<MCP client name>`) and `origin` (timer, manual, from_activities, suggested) | You can always see, filter and undo what an agent wrote. |
| 15 | Projects are one table: with a client it's an engagement (status prospect/active/closed, optional hours budget and dates), without one it's internal | Engagements and internal projects behave the same everywhere else. Presales is just a prospect engagement, so if the deal is won its history stays with the client. |
| 16 | Category (kind of work) is a second dimension next to project, not a level in a tree | "How much presales across all clients this quarter" is a simple group-by, and there's no need for an "Acme / Meetings" in every client. |
| 17 | Rules set a project, a category, or both, and each is resolved independently | "App is Zoom → Meetings" plus "title contains Acme → Acme / Phase 2" gives Acme × Meetings without one rule per combination. |
| 18 | Billable is derived (project billable AND category not never-billable) and stored on the entry, unless set explicitly | Presales stays non-billable on a billable engagement, and internal work is never billable. Storing it means later changes to defaults don't rewrite history. |
| 19 | Clients carry domains; a URL on a client's domain attributes the activity to that client even with no project | Lots of client work happens in the browser (Jira, Confluence, their admin consoles). |
| 20 | Budgets are in hours only; no rates or invoicing | waid feeds the billing system (timesheet CSV), it doesn't replace it. |

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

- `WaidCore`: `Database` (SQLite wrapper), `Store` (schema, queries, summaries), `ActivityRecorder` (writes the focus, active and locked streams from samples and lock/sleep/wake/unlock signals), `RuleEngine`, `TimeRange`, `ClaudeCodeIngestor`.
- `WaidCapture`: `MacActivitySampler`, the only macOS-specific code.
- `WaidMCP`: `MCPServer` (JSON-RPC over stdio) and `WaidTools` (the tool surface).
- `waid`: the CLI (`daemon`, `mcp`, `report`, `import`, `status`).

### Data model

```
clients       id, name, domains[]                                -- acme.com attributes URLs to Acme
projects      id, name, client_id NULL,                          -- client set = engagement, NULL = internal
              status (prospect | active | closed),               -- shown as "Acme / Phase 2" or "waid"
              billable, budget_hours, starts_on, ends_on, color
categories    id, name, billable                                 -- Presales (never billable), Implementation…
rules         id, project_id NULL, category_id NULL,             -- attribute activities at query time
              field, op, pattern, priority

observations  id, stream (focus | active | locked),              -- OBSERVED: evidence, three untrimmed streams
              source (window | agent:*),
              start_ts, end_ts,  -- end never NULL: an open observation ends at its last heartbeat
              open,              -- at most one open per (stream, source)
              zone, local_date,  -- IANA zone it happened in and its date there (ADR-0002)
              bundle_id, app_name, title, url, path,  -- focus payload; NULL on other streams
              external_id,       -- focus only; (source, external_id) unique, so importers are idempotent
              project_id, category_id, hidden, note,  -- overrides; otherwise rules decide
              meta

time_entries  id, start_ts, end_ts (NULL = running timer),       -- CLAIMED: editable, never overlapping
              zone, start_date, end_date (NULL while running),   -- local dates in the entry's zone
              project_id, category_id, title, notes, tags, billable,
              origin (timer | manual | from_activities | suggested | away),
              author (user | agent:<client>),
              status (draft | confirmed)

zone_history  id, zone, effective_ts                             -- ADR-0001; still read for ranges, going away
kv            key, value                                         -- bookkeeping and settings, e.g. importer last run,
                                                                 -- idle_threshold_seconds (default 180)
```

The schema is one CREATE block of STRICT tables, and SQLite enforces the observation rules itself: CHECKs keep `end_ts >= start_ts` and the payload and `external_id` on focus, a trigger rejects an observation overlapping another of the same stream and source (imported agent segments, which have an `external_id`, may overlap each other, since sessions run in parallel), and a trigger rejects changes to the time, identity, zone and payload of a closed observation with no `external_id`. Overrides and `meta` stay editable on any row, and imported rows stay upsertable. An Activity is a focus observation (`GLOSSARY.md`).

The closed-row trigger also freezes `open` and `external_id`: the trigger only guards rows that are closed and have no `external_id`, so reopening a row or giving it one would take it out of the trigger's reach and let its time be rewritten.

A row written without a zone of its own takes the zone you were in at its start: the zone of the nearest earlier observation the daemon recorded, else the process zone (ADR-0002). Time entries and timers take this chain unless `create_time_entry` or `update_time_entry` is given a `zone` (an IANA identifier), and so do imported agent sessions and `record_agent_work`, whose transcripts carry UTC timestamps. Imported rows don't feed the chain, since their own zone came from it. An entry's local dates are recomputed in its zone on every write.

Terms below (Summary, Evidence, Unlogged time, Report) are defined in [`GLOSSARY.md`](../GLOSSARY.md).

Claimed time:
- **Summary** (`summarize`, `waid report`): time entry totals, confirmed only unless drafts are asked for, with billable time and utilization (billable ÷ total). Grouped by client, project, category or local date. This is the number to quote and bill.

Evidence for claiming time (the `evidence` tool, `waid report --evidence|--unlogged`), never presented as claimed time:
- **Evidence**: activity totals, where your time actually went, per source and never summed across sources (decision 7). Grouped by client, project, category, app, source or local date.
- **Unlogged time**: work a suggestion would offer you to claim (stretches where one project dominates, agents excluded) that no confirmed entry covers ("3 h on Acme you haven't logged, 2.5 h of it billable"). Billable follows the project and category, as for time entries (#18). Grouped by client, project, category or local date.

Two professional-services **Reports** sit on top of Summaries:
- **Budget status**: confirmed hours against `budget_hours` per engagement, plus unconfirmed drafts, remaining hours and burn.
- **Timesheet**: one row per day × project × category, with entry titles and notes as the billing narrative, exportable as CSV.

Days in every report are **local dates**: the date where you were when the time happened, from the zone history waid records as you travel, not the zone the report runs in. A span crossing a zone change or local midnight is split, and each piece lands on its own local date. See `GLOSSARY.md` (Zone history, Local date) and [ADR-0001](adr/0001-zone-history.md). Ranges agree with those day labels: named ranges (`today`, `this_week`, …) and date-only inputs select spans by local date, and weeks start on Monday whatever the locale. Explicit RFC 3339 timestamps select exact instants.

### Suggesting entries

`suggest_time_entries` cuts the range into 1-minute buckets and labels each with the project holding most of its counted activity time, plus the category holding most of that project's time. Buckets that are idle, unattributed or contested get no label. Runs with the same project and category within 5 minutes are merged, absorbing a short interruption between them (Xcode, a quick Slack check, Xcode → one block). Time already covered by entries is cut out, blocks under 10 minutes are dropped, and each draft is titled from its biggest window titles or agent session summaries. Re-running replaces earlier suggestions in the range but never touches confirmed entries or drafts the user made.

### Capture details

- The front app is sampled every 5 s, and every sample, lock, sleep, wake and unlock is passed to the recorder with the system zone.
- `focus`: a change of app, title, URL or document starts a new observation, and the previous one is closed at the moment of the switch. Gaps longer than 3× the interval close it at its last heartbeat. Nothing is trimmed: a window left in front while you read or step away stays one observation.
- `active`: extends while input was seen within one interval of a sample, and closes at the last input instant once it wasn't. The next input opens a new one.
- `locked`: sleep, screens-did-sleep and session-resign close the open focus and active observations and open a locked one; did-wake, screens-did-wake and session-became-active close it. Sleep delivers no heartbeats, so closing on wake covers the gap.
- Before an observation is extended past local midnight in the stamp zone, it is closed at that midnight and continued in a new one, so each has one local date. On start, the recorder closes whatever a previous run left open at its stored end.
- **Present** time is the `active` stream with gaps no longer than the idle threshold T bridged. T is `idle_threshold_seconds` in `kv` (default 180 s), read at query time, and the active observations are read over the range widened by T on both sides, so a gap at a range's edge is judged by the input beyond it.
- **Attribution** (`TimeAccounting.counted`): a `window` focus observation counts its extent intersected with present time, minus locked time. Any other source (an agent session) counts its full extent, since it says nothing about whether you were present and runs behind a locked screen; agent observations never make you present. An **Activity** keeps its extent (the focus observation's start and end) and carries its counted intervals; its duration is their sum. Evidence, the suggester's bucket labelling, unlogged time and `top_uncategorized` clip each counted interval to the range rather than the extent.
- **Away** time (`Store.away(in:)`) is observed time, a window in front or the machine locked, minus present time; locked time is always away. Agent observations are not observed time for this. No tool exposes it yet.
- Claude Code transcripts (`~/.claude/projects/**/*.jsonl`) become one span per active segment. Segments split on gaps over 15 min, and spans are titled from the session summary or first prompt, with the working directory stored as `path`.

## Roadmap

**Next: make the daemon trustworthy on a real Mac**
- [ ] Dogfood for a week and tune the interval, idle threshold and sampling cost.
- [ ] Privacy controls: excluded apps/URLs, private browsing detection, a "pause tracking" switch, title redaction.
- [ ] Firefox URL capture (no AppleScript; needs AX on the URL bar or an extension).
- [ ] Signed and notarized build so the Accessibility permission sticks across updates.

**SwiftUI app**
- [ ] A menu bar item with the current activity, timer, pause control and today's total.
- [ ] Calendar import (EventKit, on-device): meetings become activities, attributed to clients by attendee domain.
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
