# Metronome project state

## Schedule calculation refactor progress

The baseline inventory, **Internal Architecture and Dependencies**,
**Nominal Schedule Calculation**, **Jitter and Deadline Planning**,
**Execution and Lifecycle Integration**, and **Optional Modules and DSL
Compatibility** categories are complete. The next category is **Deterministic
Calculation Tests**. The execution checklist is
`PLANS/PLAN-schedule-calculation-execution.md`; `PLANS/PLAN.md` is absent.
The plan remains ignored local material under `PLANS/`.

The internal boundary is `src/metronome/private/schedule.nim`. It provides
`intervalMilliseconds`, `intervalNextRun`, `cronNextRun`, `customNextRun`,
`onceNextRun`, and the inclusive `withinEndTime` filter, using only explicit
inputs, the standard library, and the existing cron evaluator. These helpers
are not re-exported by `metronome` or `metronome/scheduler` and are not supported
application APIs. Built-in calculations are deterministic for fixed inputs;
custom callbacks may capture mutable state.

`nominalFireTime` remains a thin variant-dispatch adapter. It reads the current
exported beater fields on every query and passes values directly to helpers.
There is no cached schedule model, copied cron table, or newly allocated
callback closure per occurrence. `NextRunProc` stays defined in `scheduler.nim`,
with its existing `closure, gcsafe, raises: []` contract; the private custom
helper accepts the identical structural proc signature to avoid an import
cycle or public type relocation. `BeaterKind` and the public `Beater` variant
object, including `RootObj` inheritance, remain defined in the scheduler.

The scheduler retains lifecycle, job callbacks/futures, throttling, error state,
actual launch timestamps, resume/pause tracking, and the beater-owned jitter
RNG. Interval-length measurement is shared with jitter, but random sampling
stays in `applyJitter`. Private scheduler helper `planFireTime` returns
`Option[tuple[nominal, effective: DateTime]]` and supplies both `fireTime` and
`fire`. It filters the nominal candidate before sampling, applies jitter once,
and filters the effective deadline using the same inclusive upper bound. The
live loop retains the nominal time across waiting and advances cadence from it
after a launch or throttling. Optional timer/timezone modules and their data are
unchanged. No dependency, backend, package version, or scheduling policy changed.

Internal-architecture validation on 2026-10-23:

- `nimble test`: 118 passing tests on both Nim `2.2.12` and the minimum
  supported Nim `2.2.10`; focused beater and scheduler suites also pass.
- `nimble coverage` (Nim `2.2.12`): passes, 86.5% (1902/2200 lines); the private
  calculator is included in the existing coverage filter and instrumented suites.
- `nimble docs`: passes; public `NextRunProc` remains on the scheduler page and
  the root export link still resolves. Generated timezone/timer pages remain.
- A temporary calculator-only consumer compiles and runs with `--threads:off`,
  imports no scheduler/runtime, and exercises all helper entry points.
- The fire-time example compiles with threads enabled and retains its three
  expected interval/window/cron timestamps. Its source and output are unchanged.
- `nimble build`: attempted; no binary target, with the user-confirmed waiver
  described below. `git diff --check` passes.

The dedicated calculation test matrix and final packaging/CI checks remain
in their later categories; subsequent integration results are recorded below.
Generated documentation, coverage reports/badge, caches, test binaries, and
the local execution plan remain ignored and are not committed.

## Nominal calculation contract verification

Completed on 2026-10-23, starting from `124ad09` on a clean `development`
branch. The prior category had already extracted all nominal arithmetic into
the private helpers. Reviewing every category acceptance criterion required no
further arithmetic, API, or dependency changes. Both inspection and execution
still use those same authoritative implementations through `nominalFireTime`.

Six focused regressions in `tests/test_beater.nim` confirm fractional-millisecond
alignment across a year boundary, sub-millisecond interval progression,
leap-year month/year cadence, configured cron zones returning in a non-UTC
caller's zone with inclusive upper bounds, single invocation of a stateful
custom callback, and repeated built-in results without execution-state changes.
Custom and overdue one-shot targets preserve their returned timezone and
nanosecond precision. Nil custom callbacks are rejected by both async and
thread-backed constructors. Existing tests retain start/previous-time behavior,
non-positive intervals, callback exhaustion, and upper-bound coverage.

README, top-level NimDoc, `fireTime`, `NextRunProc`, and the private helper
comments now state the nominal calculation contracts. `NextRunProc`'s comment
is attached to its declaration so it appears on the generated scheduler page;
its type, pragmas, and public identity are unchanged. Built-in nominal results
are deterministic for fixed inputs; callbacks may hold mutable state and public
`fireTime` may sample interval jitter. Example code and output are unchanged.

Validation:

- `nimble test`: 124 passing tests on Nim `2.2.12` and minimum Nim `2.2.10`;
  the focused beater suite has 43 passing tests.
- `nimble coverage`: passes at 86.5% (1904/2202 lines), above the 80% minimum.
- `nimble docs`: passes; inspected root/scheduler contract text and the
  generated timezone/timer pages remain present.
- Calculator-only smoke check: compiles and runs with threads disabled.
- Fire-time example: compiles and runs with its existing three timestamps.
- `nimble build`: attempted, returns "Nothing to build"; retain the previously
  confirmed source-library waiver, with compilation covered by tests/examples.
- `git diff --check`: passes. Validation uses the installed compilers and
  isolated Nimble/compiler caches under `/tmp`, without network access.

That category completed only the nominal-calculation checklist. Deadline
planning is recorded below; the broader lifecycle audit, dedicated calculator
suite, and final packaging remain pending. Generated artifacts and the local
plan stay ignored.

## Jitter and deadline planning

Completed on 2026-10-23, starting from `4ed61d0` on a clean `development`
branch. Both public inspection and live execution now call `planFireTime`.
This scheduler-private adapter retains nominal and effective times without a
new public type, schedule model, callback allocation, or RNG interface. Nominal
arithmetic remains in the execution-independent private calculator. Waiting,
launching, throttling, pause/resume handling, and all other lifecycle behavior
stay in the existing execution path.

Jitter arithmetic is unchanged: interval-only, measured relative to each
nominal occurrence using calendar-relative `TimeInterval` arithmetic, truncated
to milliseconds, ignored when non-positive, capped at `high(int)`, and sampled
inclusively from zero through that cap. A nominal candidate rejected by
`endTime` consumes no sample; a jittered candidate rejected afterward consumes
one. Both bounds are inclusive. Public `fireTime` advances the beater's RNG
when jitter applies and does not reserve a deadline or set runtime `nextRun`.
Independent preview and execution calls can sample different effective times.

Six added regressions in `tests/test_beater.nim` cover both jitter endpoints,
one sample per preview, non-positive/sub-millisecond windows without sampling,
non-interval schedules without sampling, precision/timezone retention,
leap-year month-relative windows and the existing integer cap, matching
inspection/runtime bounds, and nominal cadence after launches and throttling.
Tests use standard-library `privateAccess` to control the beater RNG; no public
seed API is added. An overdue prior nominal time supplied through the existing
resume input makes the cadence regression independent of wall-clock sleeps.
Completed-job callbacks are allowed an event-loop turn before checking tracking
cleanup. The dedicated calculation suite remains in its later category.

README, top-level NimDoc, `fireTime`, and `nextRun` now clarify preview RNG
effects, effective pending deadlines, calendar-relative jitter, and bounds.
The current architecture diagram and example code/output remain accurate and
unchanged. The changelog records the behavior-preserving consolidation.

Validation:

- Baseline `nimble test`: 124 passing tests on Nim `2.2.12`.
- Final `nimble test`: 130 passing tests on Nim `2.2.12` and minimum supported
  Nim `2.2.10`; the focused beater suite has 49 passing tests.
- `nimble coverage`: passes at 86.5% (1905/2202 lines), above the 80% minimum.
- `nimble docs`: passes; generated root/scheduler text is present, the private
  planner is absent from public symbol documentation, and timezone/timer pages
  remain present.
- Fire-time example: compiles and runs with its existing three timestamps.
- `nimble build`: attempted, returns "Nothing to build"; retain the previously
  confirmed source-library waiver, using tests/examples for compilation.
- `git diff --check`: passes. Validation uses installed compilers and isolated
  Nimble/compiler caches under `/tmp`, without network access.

Only the jitter/deadline checklist is completed here. No broader lifecycle,
optional-module, dedicated-suite, or packaging category was started. Generated
docs, coverage reports/badge, caches, binaries, and the local plan stay ignored.

## Execution and lifecycle integration

Completed on 2026-10-23, starting from `2a5aa24` on a clean `development`
branch. The audit confirmed that the extracted calculation boundary, shared
planner, and execution path already satisfy the lifecycle contracts. The only execution
consolidation is one nominal-cadence update after dispatch or throttling,
replacing duplicate assignments. No new execution layer, clock interface,
runtime dependency, cancellation policy, or restart guard is introduced.

Durable contracts verified by this category:

- `nominalFireTime` remains a thin adapter reading current schedule fields.
  The calculator never reads the clock; constructors and the execution side
  supply query, RNG seed, resume, launch, and error timestamps.
- `fire` publishes effective deadlines, waits with the existing clock and
  pause-generation checks, checks throttling, and uses the existing normalized
  launch/watch path. Positive sub-millisecond waits still sleep and recheck.
  Pending waits stay capped at 100 ms; polling stays at 100 ms for paused
  beaters, 10 ms for workers, and 1000 ms for scheduler idle.
- Immediate pause/resume invalidates the old wait even if state is running
  again at its next check. Interval cadence then advances from resume time;
  pending one-shots retain their deadline, including overdue occurrences.
  One-shots stop after one launch while their job future may remain active.
- Pause, stop, and stopAll leave running jobs intact. Async completion callbacks
  decrement active counts; worker completion is polled and joined before its
  future completes. Thread callbacks keep their existing pragmas and exceptions
  still do not propagate as job-future failures.
- Throttled occurrences advance nominal cadence without a backlog. Capacity
  remains configurable, finished futures are pruned, and actual `lastRun`
  timestamps remain independent from nominal times.
- Synchronous invocation failures and nil job futures still follow the same
  recording/handler path as async failures. Job handlers take precedence over
  scheduler fallback handlers; catchable handler failures remain contained.
  Async callbacks keep access to global GC-managed state without `gcsafe`.
- All eight constructor overloads retain defaults and validation. ID behavior,
  scheduler settings, startup/blocking behavior, and repeated-start semantics
  are preserved. `start()` and scheduler `waitFor()` return after startup,
  without waiting for active jobs; `serve()` runs the event loop indefinitely.

Seven added beater tests and three scheduler tests cover these integration
contracts; the existing async GC-state test now also executes a callback that
uses global state. Manually completed futures and explicit overdue nominal
inputs keep most new checks independent of wall-clock timing. Short bounded
waits cover pause polling and actual worker completion; atomics synchronize the
held worker fixture without sharing GC-managed state across threads.

README, top-level NimDoc, public lifecycle/startup comments, and CHANGELOG.md
describe the preserved behavior. The inaccurate scheduler `waitFor` comment
now describes startup rather than promising to drain jobs. Existing async,
one-shot, and fire-time examples remain accurate without source/output changes.
AGENTS.md's architecture and test layout still match the implementation.

Validation:

- Baseline `nimble test`: 130 passing tests on Nim `2.2.12`.
- Final `nimble test`: 140 passing tests on Nim `2.2.12` and minimum supported
  Nim `2.2.10`, including 56 beater and 13 scheduler tests.
- `nimble coverage`: passes at 86.9% (1938/2231 lines), above the 80% minimum;
  the standard instrumented suites exercise the private calculator unchanged.
- `nimble docs`: passes; generated root/scheduler lifecycle and startup text
  is present, and optional timezone/timer pages remain present.
- Unchanged async, one-shot, and fire-time examples compile and run with threads
  enabled. The fire-time example retains its three expected timestamps.
- `nimble build`: attempted, returns "Nothing to build"; retain the previously
  confirmed source-library build waiver, using tests/examples for compilation.
- `git diff --check`: passes. Validation uses the installed compilers and
  isolated writable Nimble/compiler caches under `/tmp`.

Only the execution/lifecycle checklist is completed here. Optional modules/DSL
compatibility is next; no later category or dedicated suite was started.
Generated docs, coverage reports/badge, caches, test binaries, and the local
plan remain ignored and are not committed.

## Optional modules and DSL compatibility

Completed on 2026-10-23, starting from `d0f3b08` on a clean `development`
branch. The existing optional adapters and macro expansion already satisfy this
category's contracts. Source changes clarify those boundaries and public
documentation; no execution logic, public type, dependency, or policy changes
were needed.

Durable boundaries and interfaces:

- `metronome/timers` owns `CalendarTimer` and adapts it to `NextRunProc` with
  one retained callback per beater. Both async and thread-backed constructors
  preserve bounds, throttle validation, and core lifecycle/error rules. The
  callback retains its parsed timer after the caller reassigns its timer or
  leaves scope. Calendar data types, parsing, and evaluation remain in separate
  optional modules; the core calculator receives only the callback.
- Both `scheduler` and blocking `metronome` use the existing shared expansion
  for `every`, `cron`, `at`, and `timer`, with both job modes. Interval fields
  and jitter, cron fields and timezone, bounds, IDs, throttle, and async handlers
  are forwarded unchanged. Thread jobs reject job-level `onError`.
- The timer DSL resolves `newTimer` and `initTimerBeater` in the caller and
  keeps its missing-import diagnostic. Importing only `metronome` includes the
  scheduler, private calculator, and cron evaluator, without timer modules,
  timezone modules, or the catalog. Compiler-generated dependencies, rather
  than just symbol visibility or binary size, verify this boundary.
- Timer adapters retain microseconds, the evaluation input's timezone, exact
  future lower-bound inclusion, inclusive upper bounds, and exhaustion. They
  preserve DST gap skipping, earlier-only overlap selection, and recurring
  timezone rules after 2037. Cron's restricted day fields keep OR semantics;
  timer weekday/date restrictions keep AND. Direct timezone conversion retains
  its separate gap normalization and overlap rules.
- The pinned IANA `2026c` catalog, updater, cron implementation, and calendar
  model/parser/evaluator are unchanged. No runtime downloads are introduced.

Eight added regressions extend the existing scheduler and timer suites.
`tests/compiler_probe.nim` compiles disposable consumers with the same compiler
as its importing suite, checking generated dependencies and 24 invalid DSL
cases across both entry macros. Temporary sources live outside `tests/`, so
the helper explicitly supplies source/thread settings and removes its scratch
directory. Valid generated callbacks are exercised once without starting
recurring fire loops; the blocking macro is checked without entering its loop.
No dedicated calculator suite or later category was started.

README, source NimDoc, AGENTS.md's test layout, and CHANGELOG.md describe the
optional adapter and verified contracts. Existing examples remain accurate
without code or output changes.

Validation:

- Baseline `nimble test`: 140 passing tests on Nim `2.2.12`.
- Final `nimble test`: 148 passing tests on local Nim `2.2.12` and minimum
  supported Nim `2.2.10`; focused scheduler/timer suites pass 16/26 tests.
- `nimble coverage`: passes at 87.0% (1949/2241 lines), above the 80% minimum.
- `nimble docs`: passes; inspected the generated root and timer adapter text,
  and verified that timezone and documentation index pages remain present.
- Unchanged timer and named-timezone cron examples compile and run with their
  expected winter/summer UTC/local timestamps and precise calendar target.
- `nimble build`: attempted, returns "Nothing to build"; retain the previously
  confirmed source-library waiver, using tests/examples for compilation.
- `git diff --check`: passes. Validation uses installed compilers, cached
  package metadata, and isolated writable Nimble/compiler directories under
  `/tmp`; minimum-version test binaries use a separate output directory.

Generated docs, coverage reports/badge, caches, test binaries, and the local
execution plan remain ignored and are not committed. Only the optional-module
and DSL category is completed here; deterministic calculation tests are next.

## Baseline snapshot

Starting snapshot, recorded on 2026-10-23:

- Branch: `development`, starting commit `9d5c65c` (`README edit`).
- Working tree: clean before this work.
- Package version: `0.5.2`; minimum Nim: `2.2.10`; local Nim: `2.2.12`
  (`8e8fbf60693418dc95bb0d762fd660231d08a583`), Linux amd64.
- The initial `nimble test` failed to compile the sub-millisecond test because a
  `gcsafe` callback referenced a top-level GC-managed `DateTime`. Moving the
  captured timestamps into a procedure restored all 108 existing tests before
  adding characterization cases. The callback type contract was retained.
- Keep work on the development branch and retain the existing version. This
  refactor does not create a release, tag, or dependency.

## Public interfaces to preserve

`src/metronome.nim` explicitly re-exports the scheduler API and `Cron`, `newCron`,
and `getNext`. Consumers may also import `metronome/scheduler` directly; type
identity and exported symbols must remain available there.

| Area | Existing public surface |
| --- | --- |
| Job callbacks | `BeaterAsyncProc`, `BeaterThreadProc`, `NextRunProc`, `JobErrorHandler` |
| Settings and logging | `Settings` with mutable `appName` and `errorHandler`, `newSettings`, `logger` |
| Throttling | `Throttler`, `initThrottler`, `throttled`, `submit` |
| Beaters | `BeaterKind`, `BeaterState`, `Beater`, `$`, eight `initBeater` overloads, `fireTime`, `fire` |
| Beater inspection | `id`, `state`, `lastRun`, `nextRun`, `lastError`, `lastErrorAt`, `failures`, `runningCount` |
| Beater controls | `pause`, `resume`, `stop` |
| Scheduler | `Scheduler`, `initScheduler`, `register`, `listJobs`, `jobState`, `stopAll`, `idle`, `start`, `serve`, `waitFor` |
| Scheduler controls and inspection | ID-based `pause`, `resume`, `stop`, `lastRun`, `nextRun`, `lastError`, `lastErrorAt`, `failures`, `runningCount` |
| DSL | `scheduler name:` and blocking `metronome:`; `every`, `cron`, `at`, caller-resolved optional `timer` |
| Optional timers | `metronome/timers`: `CalendarTimer`, string/open-array `newTimer`, `getNext`, async/thread `initTimerBeater` |

`Beater` is a `ref object of RootObj` with exported variant discriminator `kind`:

- `bkInterval`: mutable exported `interval` and `jitter` (`TimeInterval`).
- `bkCron`: mutable exported `cron` (`Cron`) and `timezone` (`Option[Timezone]`).
- `bkCustom`: mutable exported `nextRunProc` (`NextRunProc`).
- `bkOnce`: no additional exported fields.

Keep `bsRunning`, `bsPaused`, and `bsStopped`, and retain the object's variant
shape and inheritance. Calculation must read current schedule fields rather
than a second cached representation. Bounds, job callbacks, futures, counters,
errors, lifecycle state, resume timestamps, and RNG state are private.

Each interval, cron, custom, and one-shot constructor accepts an async or thread
job. Recurring constructors default to `startTime=now()` and no upper bound.
All constructors default to an empty ID, throttle 1, and no job error handler;
interval jitter defaults to zero and cron timezone defaults to none. One-shot
constructors use the supplied deadline and no upper bound. `throttleNum < 1`
raises `ValueError`. A nil custom callback raises `ValueError`. Thread-backed
constructors reject job error handlers; scheduler-level handlers are allowed
alongside thread jobs but do not capture thread exceptions.

`NextRunProc` is exactly a closure taking a `DateTime` and returning
`Option[DateTime]`, with `gcsafe` and `raises: []`. Its contract requires the first
instant strictly after the supplied input. It can capture mutable state; purity
and deterministic results are not guaranteed. Async job callbacks have no
`gcsafe` requirement and may use global GC-managed state. Thread job callbacks
retain their `gcsafe, thread` pragmas.

## Calculation inputs and behavior

The private calculation path is `nominalFireTime` -> per-kind calculation helper
-> `withinEndTime`, followed on the execution side by `applyJitter` and a second
upper-bound check. `planFireTime` owns this orchestration for both inspection
and execution. Interval calculation and jitter share `intervalMilliseconds`.

| Input or result | Meaning |
| --- | --- |
| `now` argument | Explicit query time supplied to `fireTime`; live execution reads the clock for each query |
| `prev` argument | Previous nominal occurrence, used to advance interval cadence or consume a one-shot; independent of actual launch time |
| `startTime` | Interval cadence anchor, custom query lower bound, or one-shot deadline; cron currently queries from `now` |
| `endTime` | Inclusive upper bound checked against both nominal and jittered candidates |
| Nominal occurrence | Candidate before interval jitter, retained by the live loop even when throttled |
| Effective deadline | Candidate after interval jitter; exposed as pending `nextRun` and used by the wait loop |
| `lastRun` | Clock timestamp recorded after invoking a job, including invocation normalized to a failed future |

### Per-kind rules

| Kind | No previous occurrence | Supplied previous occurrence |
| --- | --- | --- |
| Interval | Use `startTime` if it is at or after `now`; otherwise align using the interval's millisecond length measured at `startTime` | Add the calendar-relative `TimeInterval` to `prev`, even if the result is already behind `now` |
| Cron | Call existing `Cron.getNext(now)`, with optional zone conversion | Same query; ignore `prev` |
| Custom | Query `startTime - 1 nanosecond` if `startTime > now`, otherwise query `now` | Same query; ignore `prev` |
| One-shot | Return the supplied deadline, including if equal to `now` or overdue | Return none |

Initial interval alignment advances to the *next* boundary when an earlier
anchor is exactly a whole number of intervals behind `now`. For a ten-minute
interval anchored at 12:00, initial inspection at 12:30 returns 12:40. Supplying
12:00 as `prev` instead returns 12:10, with no catch-up policy added by calculation.

Initial alignment converts `startTime + interval - startTime` to milliseconds;
it must retain the existing calendar-relative arithmetic. For a one-month
interval anchored on 2026-01-01, initial inspection on 2026-02-15 returns
2026-03-04 using the anchor's 31-day length. Progression from a previous
2026-02-01 occurrence returns 2026-03-01 by adding a calendar month.

Zero and negative interval lengths are accepted today. For a past anchor, an
initial calculation returns `now`; a future anchor still returns that anchor.
With `prev`, the interval is added unchanged, including zero or negative values.
Positive intervals below one millisecond also have zero measured initial length.
Do not add validation or change the resulting live-loop behavior during extraction.

Initial alignment truncates elapsed time and interval length to whole
milliseconds, then adds the remaining wait to the original query. This retains
the query's fractional milliseconds and can differ from an exact anchor-based
duration calculation. Subsequent progression keeps the original TimeInterval
precision. Do not normalize either path while separating calculation.

Cron's configured timezone converts the query into that zone and converts the
result back to the caller's timezone. Its current evaluator may return the query
itself at a matching boundary; it does not implement custom callbacks'
strictly-later guarantee. It does not enforce `startTime`. Keep cron's existing
OR semantics for restricted day-of-month and day-of-week, and delegate all
matching to the existing evaluator without parser fixes.

Custom callbacks can return none for empty or exhausted schedules. The
one-nanosecond adjustment allows a callback to return exactly a future lower
bound. Custom and one-shot targets preserve supplied nanosecond precision;
calendar timer targets preserve microseconds. A result exactly at `endTime` is
accepted; any later result is rejected. Cron's existing evaluator normally
returns some; do not invent an exhaustion policy. Empty calendar expression
lists are rejected by `newTimer`; exhausted calendar expressions return none.
An empty scheduler starts no fire loops.

### Inspection versus live execution

`fireTime(prev, now)` calls the shared planner and returns its effective
deadline. It does not set `nextRun`, `lastRun`, lifecycle state, or counters.
It can advance the beater's RNG or invoke a stateful user callback, so it is
not universally pure.

`fire` calls the same planner. It retains both nominal and effective times,
publishes the effective time as `nextRun`, waits, and advances `prev` from
the nominal time after either dispatch or throttling. The shared planner
returns both times, avoiding another preview call and extra random samples.

Jitter is interval-only and non-negative: measure its `TimeInterval` relative to
the nominal occurrence, ignore non-positive millisecond lengths, cap at
`high(int)`, and sample the inclusive range from zero to that maximum. Each
beater owns its RNG, seeded from the clock at construction. Both pre-jitter and
post-jitter upper-bound checks must remain.

## Execution and lifecycle ownership

- `waitUntil` compares the clock with the effective deadline before returning.
  Sleeps are capped at 100 ms; a positive remainder below one millisecond causes
  a 1 ms sleep and recheck. Keep pause-generation checks so a pause/resume cycle
  invalidates a pending wait even when the state has already returned to running.
- `pause` clears `nextRun`, increments the generation, and leaves active jobs
  running. `resume` records the current time; interval execution advances from
  that time, skipping intervals missed during the pause. Pending one-shots
  survive pauses, including overdue deadlines, and stop after one launch.
- `stop` and `stopAll` prevent future launches and clear pending deadlines.
  They do not cancel active jobs. Calculation exhaustion clears `nextRun` and
  ends the fire loop without necessarily changing state from `bsRunning`.
- `Throttler.throttled` prunes finished futures and checks the configured limit.
  A throttled occurrence still advances nominal cadence and creates no backlog.
- `launch` normalizes synchronous invocation errors and nil futures into failed
  futures. `watch` tracks active count, records failures and timestamps, and
  prefers the job error handler over the scheduler handler. Catchable handler
  failures are logged and contained.
- `toAsync` creates a worker thread, polls completion every 10 ms, and joins it.
  Thread exceptions do not propagate through the job future.
- `start` starts and retains each fire-loop future with `asyncCheck`, then
  returns without waiting for jobs. Repeated starts have no restart guard.
  Scheduler `waitFor` waits for startup, not for all jobs to finish. `serve` also
  starts an infinite `idle` loop and runs the event loop forever. Preserve these
  behaviors during the refactor.
- Registration accepts anonymous and duplicate IDs. ID-based operations require
  one non-empty unique match; missing or ambiguous IDs return false, none, nil,
  or zero as appropriate. `listJobs` retains non-empty IDs including duplicates.

## Dependency and verification constraints

Core and cron remain standard-library-only. `metronome/timers` adapts a parsed
`CalendarTimer` to `NextRunProc`; its model, parser, and evaluator stay separate.
The core timer DSL resolves `newTimer` and `initTimerBeater` from the caller and
retains its missing-import diagnostic. Importing only `metronome` must not
include timer parsing or embedded IANA data. Keep the `2026c` catalog unchanged,
timer day constraints combined with AND, DST gaps skipped, and the earlier
instant chosen for overlaps. Direct timezone normalization has separate rules.

Focused baseline tests live in `tests/test_beater.nim`; architecture regressions
also cover mutations to interval, jitter, cron, timezone, and callback fields
without changing execution state. `tests/test_scheduler.nim` verifies direct
and root public type imports, callback compatibility, beater inheritance, and
that helpers are not re-exported. The existing cron, timezone, and timer suites
remain in place. Arithmetic cases use fixed UTC dates. A dedicated calculation
suite and broader boundary matrix remain later work. The nominal-calculation
category extends the beater regressions without introducing that suite. README,
NimDoc, and fire-time examples retain the existing public imports and API. No
example code or documented output needs changing for these categories.

Metronome is a source library. Compilation is exercised by the test suites;
validation does not require a package binary target. In this category,
`nimble build` was attempted and returned "Nothing to build". The user explicitly
confirmed retaining the library build waiver, using tests and examples for
compilation validation. Do not add a binary target for this refactor.

The baseline suite has 116 passing tests, and documentation generation passes.
`nimble coverage` passes with 86.3% line coverage (1876/2173 lines), above the
80% minimum. `git diff --check` passes. All baseline acceptance criteria are met.
Generated docs, reports, binaries, caches, and local plans are not committed.
CI's Nim `2.2.10` and lcov `2.1` pins remain unchanged; local validation uses
Nim `2.2.12` and lcov `2.6`.

## Deferred observation

The existing cron evaluator retains a second when rounding some fractional
queries: `2026-01-01T11:30:00.123456789Z` with hour `13`, minute `0` returns
`2026-01-01T13:00:01Z`. This was observed while writing the mutable-field test.
It is outside the calculation-boundary category; cron evaluation remains
unchanged and that regression uses a whole-second query.
