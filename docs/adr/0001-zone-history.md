# Local dates come from a zone history, not a zone on each span

People travel, and a timesheet must show Tuesday-in-Tokyo as Tuesday no matter where or when it is read. Timestamps stay UTC; waid records a zone history (the zone in effect, and from when, written by any waid process that notices a change), and every span's local date is derived from it. Date-shaped ranges ("today", "this_week", a date) select by local date; explicit timestamps are instants.

## Considered Options

- **Machine's current zone at report time** (what waid did first): simplest, but last week's Tokyo days are recomputed in the home zone after you fly back.
- **A zone stored on each activity and time entry**: an entry backfilled at home for Tokyo work gets the wrong zone, and imported agent sessions have no zone to capture. Rejected.

## Consequences

- History can't be reconstructed: anything before the first record is treated as being in the first recorded zone, and a change noticed late (daemon not running while travelling) applies from when it was noticed. Correcting the history by hand is possible later but not built.
- Spans are split at zone changes as well as at local midnight.
