# waid

A local, agent-native time tracker for professional-services work: it observes what you do, and helps you claim that time against clients, projects and kinds of work.

## Language

### Time

**Activity**:
A span of observed work, recorded automatically from a source such as the focused window or an agent session. Evidence you categorize but don't edit.
_Avoid_: event, sample, span (for the stored record)

**Time entry**:
A span of time you claim, created by a timer, by hand, or from a suggestion. What timesheets, budgets and billing use. Time entries never overlap.
_Avoid_: log, record, ledger

**Running**:
A span with no end yet. It counts up to now, and counts nothing if it starts after now.

**Zone history**:
The record of which time zone you were in, and from when. Time before the first record is in the first recorded zone; a change noticed late applies from when it was noticed.
_Avoid_: timezone setting

**Local date**:
The calendar date where you were when something happened, according to the zone history. A span's day is its local date, wherever and whenever you look at it; a span crossing midnight or a zone change has more than one.
_Avoid_: day (unqualified, when the zone matters)

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
