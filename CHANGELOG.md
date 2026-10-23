# Metronome Release Notes

## Unreleased

### Internal schedule architecture

- Moved nominal interval, cron, custom, and one-shot calculation into private
  helpers with explicit inputs and no execution/runtime dependencies. Beaters
  delegate using their current schedule fields and retain jitter, waiting,
  lifecycle, and dispatch ownership. Public scheduling APIs and behavior are
  unchanged.
- Added regression coverage for mutable schedule fields, direct scheduler type
  imports, and beater inheritance; documented the internal dependency boundary.
- Verified the nominal calculation contracts with regressions for fractional
  millisecond alignment, sub-millisecond intervals, leap-year calendar cadence,
  cron caller timezones and inclusive bounds, stateful custom callbacks, and
  precise one-shot deadlines. Clarified deterministic built-in calculation and
  callback contracts in the README and NimDoc; scheduling behavior is unchanged.
- Shared deadline planning between `fireTime` and live execution, retaining both
  nominal occurrences and jittered deadlines. Preserved beater-owned RNG
  sampling, calendar-relative jitter, inclusive bounds before and after jitter,
  and nominal cadence after launches or throttling. Added controlled jitter
  regressions and clarified preview RNG effects and pending runtime deadlines
  in the README and NimDoc; public APIs and scheduling behavior are unchanged.
- Verified execution and lifecycle integration with regressions for immediate
  pause/resume, overdue pending one-shots, active async/thread completion after
  stopping, concurrency limits and future pruning, contained handler failures,
  constructor contracts, callback GC safety, and scheduler startup semantics.
  Consolidated nominal cadence advancement after dispatch or throttling and
  clarified lifecycle/startup behavior in the README and NimDoc. Existing clock
  checks, polling, public APIs, and execution behavior are preserved.
- Verified optional timer adapters and all four DSL commands for async and
  thread-backed jobs through both entry macros. Added regressions for parameter
  forwarding, compiler diagnostics, core-only compiler dependencies, retained
  timer ownership, precise bounds, DST behavior, and distinct cron OR/calendar
  AND day matching. Clarified timer integration in the README and NimDoc;
  optional imports, public APIs, and the pinned timezone catalog are unchanged.

### Documentation

- Reviewed interval, async, cron, one-shot, named-timezone, and calendar-timer
  examples against the extracted calculation boundary. Documented the fire-time
  example's unchanged deterministic output and public preview API in README and
  NimDoc, corrected the interval example's throttle comment, and clarified that
  its blocking loop outlives schedule exhaustion. Scheduling APIs and behavior
  are unchanged; Prologue remains an optional integration dependency.
- Updated the architecture diagram and README/NimDoc guidance to distinguish
  nominal occurrences, effective pending deadlines, and actual launch timestamps.
  Clarified per-kind start bounds, inclusive deadline limits, preview RNG effects,
  direct constructor contracts, and runtime introspection. Corrected the bounds
  snippet to use the current DateTime API and keep the event loop running.
  Public scheduling APIs and behavior are unchanged.

### Development and regression coverage

- Added execution regressions for waiting on published jittered deadlines,
  nominal cadence after dispatch, active async completion while paused, and
  delayed failure reporting after `stopAll`. Strengthened sub-millisecond and
  generated async DSL callback checks, bounded lifecycle fixtures, and cleaned
  up scheduler test loops. Public APIs and scheduling behavior are unchanged.
- Added a direct deterministic calculator suite for interval alignment and
  calendar arithmetic, cron zones, precise custom/one-shot targets, exhaustion,
  and inclusive bounds. Moved arithmetic cases from the beater suite while
  retaining public delegation/state checks and controlled jitter regressions.
  The new suite runs without scheduler imports or an event loop and participates
  in standard test discovery and instrumented coverage. Scheduling APIs and
  behavior are unchanged.
- Characterized existing interval alignment, nominal cadence, calendar-relative
  arithmetic, non-positive intervals, per-kind bounds, custom callbacks, overdue
  one-shot deadlines, and calculation exhaustion before separating calculation
  from execution. Scheduling behavior and public APIs are unchanged.
- Fixed a GC-safety compilation error in the sub-millisecond deadline test by
  keeping captured timestamps local to a procedure.
- Recorded the public API and execution contracts in `PROJECT_STATE.md`.

## v0.5.1 - 2026-08-23

### Documentation

- Clarified the scheduler architecture diagram.
- Added a dedicated comparison of the scheduling DSL and direct constructors,
  including equivalent examples and guidance on when to use each API.

## v0.5.0 - 2026-08-05

### Documentation and release maintenance

- Marked Metronome as beta software and added Metronome-Web as a reference
  application.
- Added CI coverage for both `master` and `development`, including a guard
  that requires development versions to be newer than the latest release.
- Added release-tag validation that requires the tag and Nimble package
  versions to match, then tests a clean installation of every public module
  before publishing the GitHub release.
- Fixed the root compiler configuration so the documented local example
  commands resolve the package source without additional path flags.

## v0.4.3 - 2026-07-16

### Systemd-style calendar timers

- Added the optional `metronome/timers` module with systemd-style
  `OnCalendar` expressions, repeated expressions, shorthands, last-day rules,
  weekday constraints, and exact microsecond deadline calculations.
- Added `timer(onCalendar="...")` beside the existing scheduler DSL commands,
  plus direct `newTimer`, `getNext`, and `initTimerBeater` APIs.
- Added embedded IANA timezone resolution for timer suffixes, including
  deterministic DST gap, overlap, historical, and post-2037 behavior.
- Added a generic custom-schedule callback to the scheduler core and changed
  sub-millisecond waits so they are never intentionally dispatched early.
- Documented that execution remains best-effort and does not implement
  systemd service-manager options such as `AccuracySec` or `Persistent`.

### Named IANA timezone support

- Added the optional `metronome/timezones` module with `namedTimezone`,
  `timezoneDatabaseVersion`, and `timezoneNames`.
- Embedded the pinned IANA `2026c` database, including canonical names,
  aliases, historical transitions, DST metadata, and recurring future rules.
- Added a deterministic updater that pins and checksums matching `tzdata` and
  `tzcode` releases and builds the pinned `zic` instead of using the host's
  timezone compiler.
- Documented and tested timezone conversion, DST gaps and overlaps, dates
  after 2037, timezone-aware cron schedules, and Amsterdam/Chicago usage.

### Documentation and maintenance

- Moved generated API documentation and coverage artifacts out of the
  repository; CI now builds and deploys them to GitHub Pages.
- Expanded the README with an architecture overview, navigation, timer and
  timezone guidance, and clearer development documentation.
- Refactored the calendar timer implementation into focused model, parser,
  and evaluator modules, with regression coverage for overflow and DST-gap
  advancement.
- Updated project attributions and the Prologue integration example.

## v0.4.2 - 2026-07-12

- Updated the Nimble package version to `0.4.2` and regenerated its API
  documentation.

## v0.4.1 - 2026-07-12

- Removed the unnecessary `gcsafe` constraint from async jobs running on the
  event-loop thread, allowing them to access GC-managed state.
- Added regression coverage for async scheduler jobs using global GC-managed
  state and clarified the execution model in the README.

## v0.4.0 - 2026-07-11

### Breaking package and API rename

- Renamed the project and Nimble package from `nim-schedules`/`schedules` to
  Metronome/`metronome`.
- Renamed the public module, implementation namespace, and scheduling macro;
  consumers now use `import metronome` and `metronome:`.
- Updated examples, tests, documentation, CI links, and maintainer metadata for
  the new project identity.
- Marked the package as alpha software. No compatibility modules are provided
  for the former `schedules` namespace.

## Historical nim-schedules releases

The following notes describe releases made under the former `nim-schedules`
name.

## v0.3.1 - 2026-07-10

### Scheduler Reliability and Observability
- Added scheduler-level and per-job error handlers for async jobs. Failed jobs no longer stop the scheduler loop; their most recent error, failure time, and failure count are retained for inspection.
- Added job lifecycle controls: `pause(id)`, `resume(id)`, `stop(id)`, and `stopAll()`. Paused interval jobs resume from the current time rather than replaying missed intervals.
- Added job introspection APIs: `listJobs()`, `jobState(id)`, `lastRun(id)`, `nextRun(id)`, `lastError(id)`, `lastErrorAt(id)`, `failures(id)`, and `runningCount(id)`.
- ID-based lifecycle and introspection APIs require one unique, non-empty job ID; missing, anonymous, and duplicate IDs are handled safely.

### New Scheduling Capabilities
- Added one-shot scheduling with `at(time=..., id=...)`, plus `initBeater(DateTime, ...)` overloads for direct use.
- Added optional `timezone=` support for cron macros and direct cron beaters.
- Added optional non-negative interval `jitter` to spread launches over a time window without changing the base interval cadence.

### Quality, CI, and Documentation
- Added deterministic regression coverage for `fireTime` boundaries, interval rollover, and cron month/year boundaries, plus weekday `L` and `#` behavior.
- Centralized coverage-report generation for local development and CI, and made CI verify that generated documentation is current.
- Expanded the README, module documentation, and runnable examples for async jobs, timezone-aware cron, fire-time calculations, and one-shot jobs.

## Key Changes

### 1. Codebase Modernization (Nim 2.2.10 Compatibility)
- **`src/schedules/cron/cron.nim`**: Replaced deprecated `initDateTime` with standard library `dateTime` and removed the unused `initDateTime` wrapper definition.
- **`src/schedules/cron/field.nim`**: Cleaned up unused imports (`options`, `parser`).
- **`src/schedules/cron/parser.nim`**: Removed unused `parseNonSeq`.
- **`src/schedules/scheduler.nim`**: Updated macro definitions to specify return types cleanly instead of relying on deprecated `typed`/`untyped` return declarations, and removed unused imports (`tables`, `macrocache`).

### 2. Weekday Index (`#`) and Last Weekday (`L`) Matcher Bugfixes
- Fixed a calculation bug where the `#` and `L` operators (e.g. `1#3` for third Monday, `5L` for last Friday) subtracted the current day of the week (1-7) from the next matched day of the month (1-31), producing incorrect offsets.
- Resolved a crash caused by the scheduler requesting the next matched day when it had already passed in the current month, throwing an unhandled `none(int)` exception on `get`.
- Implemented `isMonthdayBased`, `getMatchMonthday`, and `getMonthdayBasedOffset` to correctly evaluate the offsets in days for these patterns in both current and subsequent months.

### 3. Expanded Test Suite
- **`tests/test_beater.nim`**: Re-enabled and uncommented the `IntervalBeater` tests by passing dummy procedures to `initBeater`.
- **`tests/test_cron.nim`**: Added comprehensive test cases validating the calculation of `1#3` (3rd Monday) and `5L` (last Friday) cron patterns.
- **`tests/test_scheduler.nim`**: Cleaned up unused imports.
- Deleted `tests/test1.nim` to remove blocking scheduler loops that hung when running automated tests.

### 4. Expanded Examples (in `examples/` folder)
- **`examples/example_blocking.nim`**: Demonstrates basic blocking and scheduling loops.
- **`examples/example_basic_intervals.nim`**: Showcases scheduler parameters including async/sync options, interval settings, throttling, and custom window ranges (`startTime`/`endTime`).
- **`examples/example_cron_scheduler.nim`**: Demonstrates various cron expressions (step syntax, list syntax, weekday indexing, and last-day-of-week).
- **`examples/example_prologue.nim`**: Demonstrates running `nim-schedules` concurrently with the Prologue web framework in one process (replacing the deprecated Jester example).

### 5. Automated CI & Code Coverage
- Added a custom `coverage` task in `schedules.nimble` that runs tests with coverage instrumentation using isolated test-specific cache directories to prevent `libgcov` checksum conflicts.
- Created `.github/workflows/ci.yml` to automatically run tests, gather coverage with `lcov`, parse overall coverage percentage, fetch a dynamic shields.io badge, and commit the badge to the repository on every commit/PR (replacing Codecov, avoiding external account dependencies).
- Updated `.github/workflows/docs.yml` to compile documentation under Nim 2.2.10.
- Updated `README.md` to document test runs, coverage commands, and local SVG badge inclusion.

### 6. Local HTML Documentation Folder
- Added a custom `docs` task in `schedules.nimble` that compiles the docstrings directly into the `docs/` folder in the repository.
- Replaced the external documentation link in `README.md` with a direct link to the local `docs/schedules.html` file, which can be easily hosted on GitHub Pages by serving the `/docs` folder on `master`/`main` branch.

## How to Verify Locally

### Run Tests
```bash
nimble test
```

### Run Coverage & Generate Badge
```bash
nimble coverage
lcov --ignore-errors inconsistent,unused --capture --directory nimcache --output-file coverage.info
lcov --ignore-errors inconsistent,unused --remove coverage.info '*/lib/*' --output-file coverage.info
genhtml --ignore-errors range --filter missing coverage.info --output-directory coverage_html
coverage_pct=$(awk -F: '/^LF:/ {lf+=$2} /^LH:/ {lh+=$2} END {if (lf>0) printf "%.1f", (lh/lf)*100; else print "0"}' coverage.info)
color=$(awk -v pct="$coverage_pct" 'BEGIN {if (pct >= 90) print "brightgreen"; else if (pct >= 75) print "green"; else if (pct >= 50) print "yellow"; else print "red"}')
mkdir -p docs
curl -s -o docs/coverage.svg "https://img.shields.io/badge/Coverage-${coverage_pct}%25-${color}"
```

### Generate Documentation
```bash
nimble docs
```
