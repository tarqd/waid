---
status: accepted
supersedes: ADR-0001
---

# Every observation and time entry carries the zone it happened in

ADR-0001 derived local dates from a zone history: one table of "which zone, from when", written by whichever waid process noticed a change. Its premises have changed. The observation layer is being rebuilt as untrimmed per-device streams (#13), sync between Macs is on the roadmap, and there is no data to migrate. We now store, on every observation and time entry, the IANA zone it happened in and its local date. Timestamps stay UTC. The daemon stamps observations with the system zone at capture, and closes and reopens each stream at local midnight so an observation has exactly one local date. Time entries may cross midnight and are split by day in reports.

Writes that have no zone of their own take, in order: a zone the caller passes (the MCP entry tools accept one, for work logged after flying home), the zone of the nearest earlier observation, then the writing process's zone. Imported agent sessions always go through that fallback. The zone is stored as an identifier such as `Asia/Tokyo`, never an offset: an offset labels the row's own date but can't turn a date back into instants across a daylight-saving change.

## Considered Options

- **Zone history only** (ADR-0001): one correction fixes everything derived, and backfilled entries get the right zone when the history knows it. But the daemon already knows each observation's zone and threw it away, the history is really per device and would need a device column and a merge rule for sync, and local dates could never be indexed or cached without invalidating on history edits. A trip with the daemon off lands silently in the home zone.
- **Zone on every row** (chosen): each row is a self-contained fact, which sync and per-device reasoning get for free, and day-shaped queries become index lookups on `local_date`. Its failures are per row and visible: a backfilled entry whose caller didn't say the zone, or a machine whose zone was wrong while travelling, fixed by a bulk update over a range.
- **Both, history as fallback**: the most accurate and the most code, with two mechanisms to explain and "which wins" rules in the glossary. Not worth it while the fallback chain above covers the zone-less cases.

## Consequences

- The `zone_history` table, its writers in the daemon, MCP server and CLI, and the "any process records a change" rule go away, along with the repeated-local-date interval logic in `TimeAccounting`.
- Date-shaped ranges (`today`, `this_week`, a date) select rows by stored local date. Explicit RFC 3339 timestamps still select instants.
- Splitting observations at local midnight, pointless under ADR-0001, is now what makes "one row, one local date" hold, so the daemon does it. Time entries are not split on write; a 23:00 to 01:00 entry is one entry and two timesheet rows.
- Per-day rollups, if ever needed, can key on `(local_date, …)` without reference to any other table.
