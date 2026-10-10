# waid

A local, agent-native time tracker for professional-services work: it observes what you do, and helps you claim that time against clients, projects and kinds of work.

## Language

### Time

**Observation**:
A stretch of one stream as the daemon saw it: what was in front (focus), when input was seen (active), or when the machine was locked or asleep (locked). An imported agent session is also an observation. Raw evidence, never shown on its own.
_Avoid_: sample, event, heartbeat, span

**Activity**:
A focus observation counting only the time you were present. Evidence you categorize but don't edit. Agent sessions count in full; they say nothing about whether you were present.
_Avoid_: event, sample, span (for the stored record)

**Time entry**:
A span of time you claim, created by a timer, by hand, or from a suggestion. What timesheets, budgets and billing use. Time entries never overlap.
_Avoid_: log, record, ledger

**Running**:
A span with no end yet. It counts up to now, and counts nothing if it starts after now.

**Open**:
An observation still being recorded. Its end is its last heartbeat, never missing, so it counts only up to that heartbeat, not up to now. Running applies to timers, not observations. At most one observation per stream and source is open; once closed, its time is fixed.
_Avoid_: running (for observations)

**Heartbeat**:
The latest instant the daemon saw an open observation still holding, stored as its end. A restarted daemon closes whatever was left open at its last heartbeat.
_Avoid_: sample (the reading that moves it)

**Present**:
The stretches when input was seen, bridged across gaps no longer than the idle threshold. The threshold is a setting, and changing it re-reads history.
_Avoid_: active (for the derived result), not idle

**Away**:
Observed time when you were not present, including while the machine was locked or asleep. What waid can ask you about afterwards.
_Avoid_: idle time, gap

**Local date**:
The calendar date where you were when something happened, recorded with it in the zone you were in. A span's day is its local date, wherever and whenever you look at it; an observation has one, and a time entry crossing midnight has more than one.
_Avoid_: day (unqualified, when the zone matters), zone history

### Claiming time

**Evidence**:
Activities viewed to help you write time entries: what you did in a range, totalled by project, client, category, app, source or day. Not a report; observed time is never presented as claimed time.
_Avoid_: activity report, summary (for activity totals)

**Unlogged time**:
Work a suggestion would offer you to claim: stretches where one project clearly dominates your activities, minus time already covered by confirmed time entries. Agent work is excluded.
_Avoid_: untracked time, missing time

### Reporting

**Summary**:
Time entry totals over a range, grouped by project, client, category or day. Always about claimed time.
_Avoid_: ledger, tally, rollup

**Report**:
A fixed-shape output built from summaries for a specific job, such as a timesheet or budget status.
_Avoid_: summary (for these)
