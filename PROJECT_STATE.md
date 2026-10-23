# Metronome project state

## Schedule calculation refactor baseline

The baseline and behavior inventory is the first implementation category in the
local schedule calculation execution plan. Its scope is characterization and
verification; schedule arithmetic and execution remain in
`src/metronome/scheduler.nim`. This category is complete. The next category is
**Internal Architecture and Dependencies**. The execution checklist is
`PLANS/PLAN-schedule-calculation-execution.md`; `PLANS/PLAN.md` is absent.
The plan remains ignored local material under `PLANS/`.

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

The current private calculation path is
`intervalMilliseconds` -> `nominalFireTime` -> `applyJitter` -> upper-bound check.
The nominal helper also checks the upper bound before jitter.

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

`fireTime(prev, now)` calls the nominal helper, samples interval jitter once,
checks the effective deadline against `endTime`, and returns it. It does not set
`nextRun`, `lastRun`, lifecycle state, or counters. It can advance the beater's
RNG or invoke a stateful user callback, so it is not universally pure.

`fire` calls the same nominal helper but currently duplicates the jitter and
post-jitter bound checks. It retains both nominal and effective times, publishes
the effective time as `nextRun`, waits, and advances `prev` from the nominal time
after either dispatch or throttling. Calling `fireTime` from the live loop would
lose that nominal value unless the adapter changes; sampling twice would change
RNG consumption. These are constraints for later extraction, not completed work.

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

Focused baseline tests live in `tests/test_beater.nim`; the existing cron,
scheduler, timezone, and timer suites remain in place. Arithmetic cases use fixed
UTC dates. No private calculation module or dedicated calculation suite exists
yet. README, NimDoc, and fire-time examples retain the existing public imports
and API. No example code or documented output needs changing for this category.

Metronome is a source library. Compilation is exercised by the test suites;
validation does not require a package binary target. Use `nimble test`,
`nimble coverage`, and `nimble docs` for the baseline category.

The expanded suite has 116 passing tests, and documentation generation passes.
`nimble coverage` passes with 86.3% line coverage (1876/2173 lines), above the
80% minimum. `git diff --check` passes. All baseline acceptance criteria are met.
Generated docs, reports, binaries, caches, and local plans are not committed.
CI's Nim `2.2.10` and lcov `2.1` pins remain unchanged; local validation uses
Nim `2.2.12` and lcov `2.6`.
