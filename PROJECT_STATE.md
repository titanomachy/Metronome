# Metronome project state

## Refactor scope and progress

The schedule-calculation/execution refactor is complete (Categories 02–14).
Its checklist is `PLANS/PLAN-schedule-calculation-execution.md`;
`PLANS/PLAN.md` is absent. Plans stay ignored local material.
`specs/` currently contains no files.

Keep work on `development`, package version `0.5.2`, Nim `>= 2.2.10`, the standard
`asyncdispatch` runtime, and dependency-free installation. This refactor adds no
release, tag, backend, compiler migration, runtime downloads, or new scheduling
policy. Metronome is a source library: the user confirmed that tests and examples
provide compilation validation; do not add a binary target to satisfy
`nimble build` (which reports "Nothing to build").

## Architecture and interfaces

`src/metronome/private/schedule.nim` owns explicit-input nominal calculation:
`intervalMilliseconds`, `intervalNextRun`, `cronNextRun`, `customNextRun`,
`onceNextRun`, and inclusive `withinEndTime`. Dependencies are the standard
library and existing cron evaluator. No scheduler, jobs/futures, event loop,
threads, clocks, sleeps, logging, RNG, timer parser, or timezone catalog belongs
here. Built-in calculations are deterministic for fixed inputs; callbacks may
capture mutable state. Helpers are not supported application APIs or re-exported
by `metronome` / `metronome/scheduler`.

`nominalFireTime` in `scheduler.nim` is a thin variant adapter reading current
exported fields on every query. Keep one authoritative implementation, without
a cached schedule model, copied cron tables, or per-occurrence callback
allocation. `NextRunProc` remains defined in the scheduler; the private helper
accepts its identical structural signature to avoid a cycle or type relocation.

Private `planFireTime` supplies both `fireTime` and `fire` with
`Option[tuple[nominal, effective: DateTime]]`. It checks the nominal upper bound,
applies jitter once, then checks the effective upper bound with `withinEndTime`.
The live loop retains the nominal time while waiting and advances cadence from
it after dispatch or throttling. Lifecycle, jobs/futures, throttling, counters,
actual launch/error timestamps, resume tracking, pause generations, and per-beater
RNG stay in the scheduler.

`src/metronome.nim` explicitly exports the scheduler API and `Cron`, `newCron`,
`getNext`. Direct `metronome/scheduler` imports retain the same types and symbols.

| Area | Public surface to preserve |
| --- | --- |
| Callbacks | `BeaterAsyncProc`, `BeaterThreadProc`, `NextRunProc`, `JobErrorHandler` |
| Settings/logging | Mutable `Settings.appName` / `errorHandler`, `newSettings`, `logger` |
| Throttling | `Throttler`, `initThrottler`, `throttled`, `submit` |
| Beaters | `BeaterKind`, `BeaterState`, `Beater`, `$`, eight `initBeater` overloads, `fireTime`, `fire` |
| Inspection | `id`, `state`, `lastRun`, `nextRun`, `lastError`, `lastErrorAt`, `failures`, `runningCount` |
| Controls | Beater and ID-based scheduler `pause`, `resume`, `stop` |
| Scheduler | `Scheduler`, `initScheduler`, `register`, `listJobs`, `jobState`, `stopAll`, `idle`, `start`, `serve`, `waitFor`, ID-based inspection |
| DSL | `scheduler name:` and blocking `metronome:`; `every`, `cron`, `at`, caller-resolved optional `timer` |
| Optional timers | `CalendarTimer`, string/open-array `newTimer`, `getNext`, async/thread `initTimerBeater` |

`Beater` remains a `ref object of RootObj` with exported variant discriminator
`kind`: `bkInterval` has mutable `interval` / `jitter`; `bkCron` has `cron` /
`timezone`; `bkCustom` has `nextRunProc`; `bkOnce` has no extra exported fields.
Retain `bsRunning`, `bsPaused`, `bsStopped`; all execution fields remain private.

Each kind has async and thread constructors. Recurring defaults are
`startTime=now()`, no upper bound, empty ID, throttle 1, no job error handler;
interval jitter is zero and cron timezone is none. One-shots use their supplied
deadline without an upper bound. Direct APIs take Option-valued bounds/timezones,
`throttleNum`, and `errorHandler`; DSL uses plain values and existing parameter
names. Invalid throttle (<1), nil custom callbacks, and thread job-level error
handlers raise `ValueError`; the DSL retains its thread `onError` diagnostic.

`NextRunProc` takes `DateTime`, returns `Option[DateTime]`, and retains
`closure, gcsafe, raises: []`. It must return the first instant strictly after
its input or none, and should return promptly on the event loop. Async jobs
retain access to global GC-managed state without a `gcsafe` requirement; thread
callbacks retain `gcsafe, thread`. Scheduler handlers may accompany thread jobs
but cannot receive thread exceptions through job futures.

## Calculation and deadline contracts

`prev` is a previous nominal occurrence, independent of actual `lastRun`.
`fireTime(prev, now)` receives an explicit query time; live execution reads the
clock. `endTime` is inclusive for nominal and effective deadlines. It does not
limit job completion or prevent dispatch delayed beyond that bound.

| Kind | No previous occurrence | Supplied previous occurrence |
| --- | --- | --- |
| Interval | Select `startTime` when at/after query; otherwise align by whole milliseconds measured at the anchor | Add the calendar-relative `TimeInterval` to `prev`, even if still overdue |
| Cron | Query existing `Cron.getNext(now)` with optional zone conversion | Same query; ignore `prev` |
| Custom/timer | Query `startTime - 1 nanosecond` if the start is future; otherwise query `now` | Same query; ignore `prev` |
| One-shot | Return precise deadline, including at/past query | Return none |

Initial interval alignment selects the next boundary when a past anchor is
exactly a whole number of intervals behind the query: 12:00 + ten-minute
interval queried at 12:30 gives 12:40; supplying 12:00 as `prev` gives 12:10.
Initial measurement retains calendar-relative anchor length: a one-month
interval anchored 2026-01-01 queried 2026-02-15 gives 2026-03-04 (31-day length),
while progression from 2026-02-01 gives 2026-03-01. Elapsed/interval measurement
truncates to milliseconds, then adds remaining wait to the original query,
retaining its fractional milliseconds. Do not normalize these characterized
semantics into fixed durations or successive-month alignment.

Zero/negative intervals remain accepted. With a past anchor and non-positive
measured length, initial calculation returns the query; a future anchor still
wins. With `prev`, add the interval unchanged. Positive intervals below 1 ms
also measure zero initially, but retain precision during subsequent addition.
Do not add interval validation or change live-loop behavior in this refactor.

Cron uses the existing evaluator, including matching-boundary inclusion,
restricted day-of-month/day-of-week OR semantics, and no `startTime` enforcement.
Configured zones convert the query into that zone and the result back into the
caller's zone. Do not impose the custom strictly-later contract on cron.
Custom callbacks are invoked once per query, may exhaust, and preserve returned
timezone/nanoseconds. The future-start adjustment includes that exact bound.
One-shots retain nanoseconds; calendar targets retain microseconds. Empty timer
expression lists are rejected; exhausted timers return none.

Jitter is interval-only, calendar-relative to each nominal occurrence, truncated
to milliseconds, ignored if non-positive, capped at `high(int)`, and sampled
inclusively from zero to that cap. RNG is beater-owned and seeded at construction.
Rejected nominal bounds consume no sample; rejection after jitter consumes one.
`fireTime` invokes callbacks / samples RNG without setting runtime `nextRun`,
`lastRun`, counters, or lifecycle state; previews do not reserve deadlines and
independent preview/execution calls can differ. `nextRun` simply reads the
pending effective deadline; `lastRun` records the clock after job invocation.

## Execution and lifecycle contracts

- `waitUntil` rechecks the clock against the effective deadline. Waits cap at
  100 ms; a positive sub-millisecond remainder sleeps 1 ms and rechecks.
  Pause-generation checks invalidate waits even after immediate pause/resume.
- `pause` clears `nextRun`, increments the generation, and leaves active jobs
  running. `resume` records the clock; interval cadence advances from resume time
  without replaying missed intervals. One-shots remain pending across pauses,
  including overdue deadlines, and stop after one launch while jobs may remain.
- `stop` / `stopAll` clear pending deadlines and prevent launches without
  cancellation. Exhaustion clears `nextRun` and ends the fire loop without
  necessarily changing `bsRunning` to `bsStopped`.
- Throttling prunes completed futures and respects configurable capacity.
  Throttled occurrences advance nominal cadence without a backlog. Completion
  callbacks settle async counts; worker completion is polled every 10 ms and
  joined before its future completes. Thread exceptions do not fail job futures.
- `launch` normalizes synchronous invocation errors and nil futures into failed
  futures. `watch` records failures/timestamps and prefers job handlers over
  scheduler fallbacks; catchable handler failures are logged and contained.
  Active jobs can complete/fail after pause or stop and still update inspection.
- `start` retains fire-loop futures with `asyncCheck` and returns after startup;
  repeated starts have no restart guard. Scheduler `waitFor` waits for startup,
  not job completion. `serve` runs an infinite idle/event loop, even after all
  schedules exhaust. Paused polling is 100 ms; scheduler idle is 1000 ms.
- Anonymous/duplicate IDs remain valid registrations. ID operations require a
  unique non-empty match and otherwise return false/none/nil/zero as appropriate.
  `listJobs` includes non-empty duplicates.

## Optional modules, docs, and packaging

Core and cron use only the standard library. `metronome/timers` adapts parsed
`CalendarTimer` to one retained `NextRunProc` per beater, preserving ownership
after the caller reassigns its timer or leaves scope. Calendar model, parser,
and evaluator remain separate. The timer DSL resolves `newTimer` /
`initTimerBeater` from the caller and keeps its missing-import diagnostic.
Core-only imports must not include timer parsing or timezone modules/catalog.
Keep IANA `2026c` unchanged, calendar day matching AND, spring gaps skipped,
earlier-instant overlaps, and recurring rules after 2037. Direct timezone
conversion keeps its separate gap normalization and overlap rules.

Nimble `srcDir = "src"` includes all nested modules and pinned data at install.
Copy `tests/fixtures/installed_package_smoke.nim` outside the checkout and run
its five `packageSmoke` modes with only the installed path,
`--noNimblePath`, and user/parent/project configurations disabled; compare all
installed source/data bytes. Separate root, scheduler, cron, timezone, and timer
consumers protect public imports and optional boundaries.

`nimble docs` retains the private calculator HTML for scheduler import links,
but removes `docs/metronome/private/schedule.idx` before API-index generation.
Private helpers must stay out of supported API search/navigation. Preserve root,
scheduler, timezone, and timer pages and the 57 canonical scheduler export links.
Edit source NimDoc rather than generated HTML. CI pins Nim `2.2.10` / lcov `2.1`,
runs canonical docs/coverage tasks, and enforces 80% line coverage. Local tools
are Nim `2.2.12` and lcov `2.6`. PRs validate; only master pushes deploy Pages.
No backend matrix or generated documentation/badge commits belong in this work.
Generated docs, reports/badge, caches, binaries, local Nimble files, plans, and
logs stay ignored.

## Test and example boundaries

`tests/test_schedule_calculation.nim` owns direct fixed-input arithmetic,
per-kind bounds/precision/zones/exhaustion/repeatability tests without scheduler,
futures, clocks, sleeps, RNG, or named-zone data. It also runs with threads off.
`test_beater.nim` retains public delegation/mutable-field/state compatibility,
controlled private RNG checks (std/importutils, no public seed API), deadline
waiting, cadence, lifecycle, concurrency, and failure tests. `test_scheduler.nim`
retains public type/import/inheritance and DSL/ID/startup/GC-state tests.
`tests/compiler_probe.nim` compiles disposable consumers with its suite's own
compiler for dependency information and 24 invalid DSL cases. Its calculator-only
probe disables threads and rejects scheduler, async futures, RNG/logging, and
optional timer/timezone dependencies; keep that probe in the scheduler suite so
the direct calculator suite remains free of process/execution imports.
Cron/timezone/timer suites retain host-independent DST, post-2037, precision,
and adapter coverage.
`tests/config.nims` supplies source path / threads; avoid redundant flags.

Live fixtures use bounded tolerant waits and clean up loops/jobs. The positive
500-microsecond target is created during custom calculation to avoid setup
latency exhausting it. Cadence tests use explicit overdue nominal inputs where
possible; live jitter checks compare published deadlines with actual launches
without an upper latency bound. Completed futures need an event-loop turn for
tracking cleanup; held worker fixtures use atomics without GC-shared state.

`nimble test` discovers all six suites. `code_coverage.sh` instruments each with
its own cache, including `nimcache/schedule_calculation`, and retains `src/*`
filtering. Every private helper must execute; do not lower the 80% threshold or
exclude new logic. Minimum/local compiler-generated totals can differ.

Examples use supported public imports. The fire-time example uses fixed UTC
inputs, zero jitter, and an uninvoked async job; it starts no event loop and sets
no runtime deadline. Its assertions keep `nextRun`/`lastRun` empty and
`runningCount` zero after previews. README/NimDoc output stays: interval/window
previews `2026-01-01T12:40:00Z`, cron `2027-01-01T00:00:00Z`. Interval examples use default
thread-job throttle 1 and explain blocking-loop lifetime. Named-zone/timer
examples retain optional imports, winter/summer offsets, and microseconds.
Prologue stays optional; compile it only when its integration changes and its
dependencies are available.

## Known caveats and deferred work

- Existing cron fractional-query rounding can retain a second:
  `2026-01-01T11:30:00.123456789Z` queried for hour 13/minute 0 gives
  `2026-01-01T13:00:01Z`. Do not fix cron evaluation in this refactor.
- Nim `2.2.12` generates 112 broken duplicate root re-export links with `_2` /
  `_3` suffixes, alongside 57 working canonical scheduler links. Fresh baseline
  docs from `50ed70f` have the same set. Preserve canonical visibility and avoid
  treating this generator defect as a new refactor regression.
- Chronos, Nimony, polling optimization, cancellation, worker pools, persistent
  catch-up, new scheduling policies, and unrelated parser fixes remain separate
  work. Chronos needs a concrete consuming runtime requirement; Nimony needs a
  compiling prototype before compatibility claims or migration plans.
