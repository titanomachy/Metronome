# Metronome Release Notes

## Unreleased

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
