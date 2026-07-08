# Release Notes - nim-schedules Upgrade & Bugfixes

This release modernizes `nim-schedules` to support Nim 2.2.10, resolves compiler warnings, resolves critical cron weekday matcher bugs, restructures and expands the test suite, configures local/CI code coverage, and introduces new examples.

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
- Created `.github/workflows/ci.yml` to automatically run tests, gather coverage with `lcov`, and upload to Codecov on every commit and PR.
- Updated `.github/workflows/docs.yml` to compile documentation under Nim 2.2.10.
- Updated `README.md` to document test runs, coverage commands, and badges (with `<your-github-username>` placeholders).

### 6. Local HTML Documentation Folder
- Added a custom `docs` task in `schedules.nimble` that compiles the docstrings directly into the `docs/` folder in the repository.
- Replaced the external documentation link in `README.md` with a direct link to the local `docs/schedules.html` file, which can be easily hosted on GitHub Pages by serving the `/docs` folder on `master`/`main` branch.

## How to Verify Locally

### Run Tests
```bash
nimble test
```

### Run Coverage
```bash
nimble coverage
lcov --ignore-errors inconsistent --capture --directory nimcache --output-file coverage.info
lcov --ignore-errors inconsistent --remove coverage.info '*/lib/*' --output-file coverage.info
genhtml --ignore-errors range --filter missing coverage.info --output-directory coverage_html
```

### Generate Documentation
```bash
nimble docs
```
