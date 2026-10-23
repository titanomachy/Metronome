# Metronome

> [!WARNING]
> **Beta Notice:** Metronome is a pre-1.0 package under active development.
> While it is fully functional today, future releases may introduce breaking changes,
> and the public API offers no backward compatibility guarantees.

[![CI](https://github.com/titanomachy/Metronome/actions/workflows/ci.yml/badge.svg)](https://github.com/titanomachy/Metronome/actions/workflows/ci.yml)
[![Coverage](https://titanomachy.github.io/Metronome/coverage.svg)](https://github.com/titanomachy/Metronome/actions)

Metronome is a Nim library for time-based job scheduling supporting cron jobs, systemd-style timers, interval-based timers, and one-shot tasks.

See [Metronome Web](https://github.com/titanomachy/Metronome-Web) for an example application build with Metronome.

Read the [documentation](https://titanomachy.github.io/Metronome/metronome.html).

Features:

* Simple to use API for scheduling jobs.
* Support scheduling both async and sync procs.
* Interval, cron, systemd-style timers, and one-shot scheduling.
* Timezone-aware cron and systemd-style calendar schedules, including optional embedded IANA names.
* Job-level and scheduler-level async error handling.
* Pause, resume, stop, and inspect registered jobs by id.
* Optional interval jitter to spread out job launches.
* Zero-dependency code

## How Metronome Fits Together

Each schedule creates a beater that owns one job's timing and state. A
scheduler owns the registered beaters, starts their execution loops, applies
lifecycle controls, and exposes job state for inspection. Each beater dispatches
its job through either the async event loop or a worker thread.

The beater delegates nominal occurrence calculation to internal helpers using
its current schedule fields and explicit time inputs. It owns jitter, waiting,
throttling, and execution state. The internal helpers use only the standard
library and existing cron evaluator; they calculate occurrences without reading
a clock or starting jobs. Calendar timers supply their evaluator through the
core's custom-schedule callback, keeping timer parsing and IANA data optional.

```mermaid
flowchart TB
  DSL(["Metronome DSL / Direct Constructors"]):::entry

  subgraph INTERFACES["Scheduling Triggers"]
    direction LR
    EVERY["Interval"]:::trigger
    CRON["Cron"]:::trigger
    TIMER["Calendar Timer"]:::trigger
    AT["One-Shot"]:::trigger
  end

  BEATER["Beater"]:::core
  CALCULATION["Nominal Schedule Calculation"]:::core
  PLANNING["Beater Deadline Planning<br/>Bounds and Interval Jitter"]:::core
  EXECUTION["Beater Execution<br/>Wait and Recheck Lifecycle"]:::core
  SCHEDULER["Scheduler"]:::core
  GATE{"Throttle Capacity Available"}:::gate
  ASYNC["Async Event Loop"]:::target
  THREAD["Worker Thread (Default)"]:::target

  DSL --> INTERFACES
  EVERY --> BEATER
  CRON --> BEATER
  TIMER --> BEATER
  AT --> BEATER

  SCHEDULER -->|Owns and controls| BEATER
  BEATER -->|Current fields and explicit time inputs| CALCULATION
  CALCULATION -->|Nominal occurrence| PLANNING
  PLANNING -->|Effective deadline: nextRun| EXECUTION
  EXECUTION --> GATE
  GATE -->|async = true| ASYNC
  GATE -->|async = false| THREAD

  %% Styling palette
  classDef entry fill:#e8f0fe,stroke:#4285f4,stroke-width:2px,color:#174ea6;
  classDef trigger fill:#f1f3f4,stroke:#5f6368,stroke-width:1.5px,color:#202124;
  classDef core fill:#e6f4ea,stroke:#34a853,stroke-width:2px,color:#137333;
  classDef gate fill:#fef7e0,stroke:#f9ab00,stroke-width:2px,color:#b06000;
  classDef target fill:#fce8e6,stroke:#ea4335,stroke-width:1.5px,color:#c5221f;
```

- **Interval Scheduling:** Fixed intervals with optional jitter.
- **Cron Scheduling:** Minute resolution with optional IANA timezones.
- **Calendar Timer:** Microsecond-precision systemd-style targets with optional IANA timezones.
- **One-Shot Scheduling:** Single deadline execution.
- **Beater:** Manages one job's deadline, ID, throttle limit, bounds, and execution state.
- **Nominal Schedule Calculation:** Evaluates interval, cron, custom, and one-shot candidates from explicit inputs, before jitter.
- **Scheduler:** Owns beaters, applies lifecycle controls (`pause`, `resume`, `stop`), and provides state/run queries.
- **Deadline Planning:** Checks inclusive bounds before and after interval jitter; shared by `fireTime` and live execution.
- **Beater Execution:** Publishes `nextRun`, waits for that deadline, and checks lifecycle state and throttle capacity before launching.

### Occurrences, Deadlines, and Launches

| Time | Meaning | API |
| --- | --- | --- |
| Nominal occurrence | Schedule time before jitter; interval cadence advances from this time even when throttled. | The `prev` argument to `fireTime` takes the previous nominal occurrence. |
| Effective deadline | Nominal occurrence plus any interval jitter; waiting uses this deadline. | `fireTime` computes a candidate; `nextRun` reports the runtime's pending deadline. |
| Actual launch timestamp | Wall-clock time recorded after invoking the job; system load and job code can delay it. | `lastRun` records this time, independently of job completion. |

For a ten-second interval, a nominal occurrence at `12:00:00` with `200 ms`
jitter gives a `12:00:00.200` deadline. The next nominal occurrence remains
`12:00:10`, regardless of that delay or the job's duration. Dispatch is
best-effort; the deadline is not a guarantee of the actual launch time.

## Contents

- [Metronome](#metronome)
  - [How Metronome Fits Together](#how-metronome-fits-together)
    - [Occurrences, Deadlines, and Launches](#occurrences-deadlines-and-launches)
  - [Contents](#contents)
  - [Getting Started](#getting-started)
  - [Usage](#usage)
    - [Thread Requirements](#thread-requirements)
  - [Advanced Usage](#advanced-usage)
    - [DSL vs. Direct Constructors](#dsl-vs-direct-constructors)
    - [Cron](#cron)
      - [Cron Syntax](#cron-syntax)
    - [Schedule by Timer](#schedule-by-timer)
    - [One-Shot Jobs](#one-shot-jobs)
    - [Throttling](#throttling)
    - [Customize Scheduler](#customize-scheduler)
    - [Set Start Time and End Time](#set-start-time-and-end-time)
    - [Runnable Examples](#runnable-examples)
    - [Calculate Next Run Times](#calculate-next-run-times)
    - [Error Handling](#error-handling)
    - [Interval Jitter](#interval-jitter)
    - [Job Controls](#job-controls)
    - [Job Introspection](#job-introspection)
  - [Changelog](#changelog)
  - [Development](#development)
    - [Running Tests](#running-tests)
    - [Code Coverage](#code-coverage)
    - [Documentation](#documentation)
    - [Updating the embedded timezone database](#updating-the-embedded-timezone-database)
  - [License](#license)
  - [Attributions](#attributions)

## Getting Started

Requires Nim `>= 2.2.10` and has no third-party package dependencies. Applications
that import `metronome` compile with threads enabled, including async-only jobs.

```bash
nimble update
nimble install metronome
```

If a feature is not yet in a release, you can try the active development branch.
```bash
nimble install metronome@#development
```

## Usage

This introductory example uses both execution paths: a regular procedure runs
in its own worker thread, while the procedure marked `async=true` runs on the
async event loop.

```nim
# File: examples/example_getting_started.nim
import metronome, times, asyncdispatch

metronome:
  every(seconds=10, id="tick"):
    echo("tick", now())

  every(seconds=10, id="atick", async=true):
    echo("tick", now())
    await sleepAsync(3000)
```

1. Schedule thread proc every 10 seconds.
2. Schedule async proc every 10 seconds.

Run:

```bash
nim c --threads:on -r examples/example_getting_started.nim
```

Scheduling is affected by system load, so launch times should not be treated as
real-time deadlines.

### Thread Requirements

Compile applications that import `metronome` with `--threads:on`:

```bash
nim c --threads:on your_app.nim
```

An `every`, `cron`, `timer`, or `at` block without `async=true` becomes a
thread-backed job. Its body must satisfy Nim's thread and GC-safety rules, and
blocking work inside it blocks only that worker thread. A block with
`async=true` runs on the async event loop; use `await` for long-running work
because blocking calls in that body stall the event loop. Async job failures
can be tracked and handled; exceptions from thread-backed jobs are not
propagated through job futures.

The repository's tests already enable threads through `tests/config.nims`, but
applications and ad hoc example builds should pass the flag explicitly.

## Advanced Usage

### DSL vs. Direct Constructors

The scheduling DSL is the shortest way to declare jobs and is the recommended
starting point. The `metronome` and `scheduler` macros turn each `every`,
`cron`, `timer`, or `at` block into a `Beater` and register it with a
`Scheduler`. The direct constructors expose those same runtime objects; they
do not use a different scheduling engine.

| DSL declaration | Direct construction |
| --- | --- |
| `every(...)` | `initBeater(initTimeInterval(...), ...)` |
| `cron(...)` | `initBeater(newCron(...), ...)` |
| `timer(...)` | `initTimerBeater(newTimer(...), ...)` |
| `at(...)` | `initBeater(dateTime, ...)` |

For example, this DSL application creates an async interval job and starts a
blocking scheduler:

```nim
import metronome, times, asyncdispatch

metronome:
  every(seconds=10, id="tick", async=true):
    echo "tick"
```

The equivalent direct construction makes each step explicit:

```nim
import metronome, times, asyncdispatch

proc tick(): Future[void] {.async.} =
  echo "tick"

let sched = initScheduler(newSettings())
let tickBeater = initBeater(
  interval=initTimeInterval(seconds=10),
  asyncProc=tick,
  id="tick"
)

sched.register(tickBeater)
sched.serve()
```

Direct construction is useful when jobs are assembled dynamically at runtime,
when scheduler-level settings such as an error handler are required, when the
application needs to retain and inspect a `Beater`, or when a custom schedule
is supplied through `NextRunProc`. It can also be convenient when job bodies
already exist as named procedures.

Direct bounds and cron timezones use `Option` values (`some(...)` or `none(...)`
from `options`); the DSL wraps plain values for you. Direct constructors use
`throttleNum` and `errorHandler` where the DSL uses `throttle` and `onError`.
The public `NextRunProc` callback supplies custom schedules; it must be non-nil,
`gcsafe`, and `raises: []`. During live scheduling it runs on the event-loop
thread and should return promptly. Async job bodies can access GC-managed state.

Use `scheduler name:` instead of `metronome:` when you prefer the DSL but need
to retain the scheduler and call `name.start()` or `name.serve()` yourself.

### Cron

You can use `cron` to schedule jobs using cron-like syntax.

```nim
import metronome, times, asyncdispatch

metronome:
  cron(minute="*/1", hour="*", day_of_month="*", month="*", day_of_week="*", id="tick"):
    echo("tick", now())

  cron(minute="*/1", hour="*", day_of_month="*", month="*", day_of_week="*", id="atick", async=true):
    echo("tick", now())
    await sleepAsync(3000)
```

1. Schedule thread proc every minute.
2. Schedule async proc every minute.

#### Cron Syntax

The `cron` macro accepts six string fields. Omitted fields default to `"*"`.
Cron scheduling has one-minute resolution.

| Field | Values | Names |
| --- | --- | --- |
| `minute` | `0-59` | — |
| `hour` | `0-23` | — |
| `day_of_month` | `1-31` | — |
| `month` | `1-12` | `jan` through `dec` |
| `day_of_week` | `1-7` | `mon` through `sun` |
| `year` | `1970-9999` | — |

Field text is case-insensitive. These forms can be combined in a field:

| Syntax | Meaning | Example |
| --- | --- | --- |
| `*` | every allowed value | `hour="*"` |
| `a,b` | a list of values | `minute="0,30"` |
| `a-b` | an inclusive range | `day_of_week="mon-fri"` |
| `*/n`, `a/n`, `a-b/n` | steps through all values, from a value, or through a range | `minute="*/5"` |
| `L` or `last` | last day of the month; `day_of_month` only | `day_of_month="L"` |
| `dL` | last weekday `d` of the month; `day_of_week` only | `day_of_week="friL"` |
| `d#n` | nth weekday `d` of the month; `day_of_week` only | `day_of_week="mon#3"` |

When both `day_of_month` and `day_of_week` are restricted, a date matching
either field is selected. Although the low-level parser currently recognizes
`?` and `W`, the next-run evaluator does not implement them; do not use those
forms in schedules.

Direct `newCron` calls expose a `second` argument for API compatibility, but
the current next-run calculation is minute-based and does not evaluate it.

Cron schedules can also be evaluated in a specific Nim `Timezone` by passing
`timezone=`. UTC needs no additional module:

```nim
import metronome, times, asyncdispatch, options

metronome:
  cron(hour="9", minute="0", id="utc-daily", async=true, timezone=utc()):
    echo("09:00 UTC ", now())
```

Direct `initBeater` calls accept `timezone=some(myTimezone)`.

For a named IANA zone, import the optional `metronome/timezones` module and
resolve the name once when constructing the scheduler:

```nim
import metronome, metronome/timezones
import asyncdispatch, times

# Change this one value to "America/Chicago" to move the schedule.
let zone = namedTimezone("Europe/Amsterdam")

scheduler localSched:
  cron(hour="9", minute="0", id="local-daily", async=true, timezone=zone):
    echo("09:00 local: ", now().inZone(zone))
```

Cron fields remain local wall-clock values. A 09:00 Amsterdam job therefore
runs at 08:00 UTC in winter and 07:00 UTC in summer. The embedded data is
cross-platform and does not read system zoneinfo files or perform runtime
downloads. Importing only `metronome` does not include or initialize it.
The `2026c` catalog is 411,023 bytes. In an illustrative stripped Linux x86-64
Nim 2.2.10 build, adding `metronome/timezones` increased a minimal executable
from 77,304 to 528,120 bytes; exact overhead depends on the target and compiler
settings.

Names are exact and case-sensitive. Canonical names and IANA aliases are
accepted, including `Etc/UTC` and `UTC`; `LOCAL`, numeric offsets, filesystem
paths, and unknown abbreviations are rejected. During a spring-forward gap, a
nonexistent local time is normalized forward. During a fall-back overlap, the
earlier occurrence is selected.

Use `timezoneDatabaseVersion()` to report the bundled IANA release and
`timezoneNames()` to list supported names. Database updates are application
updates: governments can change future rules, so applications should update
Metronome when a newer database is released. The generated API documentation
for this optional module is in
[`metronome/timezones`](https://titanomachy.github.io/Metronome/timezones.html).

See [example_cron_scheduler.nim](examples/example_cron_scheduler.nim) for
lists, `#`, and `L`, and
[example_cron_timezone.nim](examples/example_cron_timezone.nim) for timezone
handling.

### Schedule by Timer

Import the optional `metronome/timers` module to use a systemd-style
`OnCalendar` expression beside `every` and `cron`:

```text
Syntax: Year-Month-Day Hour:Minute:Second TimeZone
Example: OnCalendar=*-*-* 02:00:00 Europe/Amsterdam
```

```nim
import metronome
import metronome/timers

scheduler timerSched:
  timer(
    onCalendar="*-*-* 02:00:00 Europe/Amsterdam",
    id="nightly",
    async=true
  ):
    echo "Running nightly"
```

`metronome/timers` already includes the embedded timezone resolver used by
`OnCalendar` suffixes, so this example does not need a separate
`metronome/timezones` import. Import that module explicitly only when calling
its public APIs, such as `namedTimezone`, `timezoneNames`, or
`timezoneDatabaseVersion`, from application code.

Both `scheduler` and `metronome` support async and thread-backed timer jobs.
The DSL resolves the timer API from your imports and reports a missing
`metronome/timers` import at compile time. Direct `initTimerBeater` overloads
adapt a parsed `CalendarTimer` to the core's custom-schedule callback, retaining
the timer for the beater's lifetime. They share the core's bounds, throttling,
and lifecycle controls; job-level `onError` is available only with `async=true`.

The optional weekday prefix, `*`, comma-separated lists, `..` ranges, `/`
repetitions, `~` last-day forms, and the standard `minutely` through
`semiannually` shorthands are supported. A timer may also combine repeated
expressions:

```nim
let reporting = newTimer(["daily UTC", "Mon *-*-* 09:00:00 Europe/Amsterdam"])
```

Explicit `UTC` and exact embedded IANA names are resolved once. If the suffix
is omitted, the input `DateTime` timezone is used. Weekday and date constraints
must both match (AND); cron uses OR when both day fields are restricted.
Nonexistent wall-clock occurrences in a DST gap are skipped;
an overlap uses its earlier occurrence.

The seconds field accepts fractions, such as
`*-*-* *:*:00.123456 UTC`. Calendar matching and `getNext` retain one
microsecond of resolution, making timers more expressive than Metronome's
minute-resolution cron evaluator. The async event-loop wait is normally
millisecond-scale and affected by operating-system load, so dispatch is
best-effort rather than a real-time guarantee.

This interface models systemd's calendar-event grammar, not complete `.timer`
units. It does not implement `AccuracySec`, persistent catch-up, randomized
delay, monotonic boot timers, or wake-from-suspend. See the
[systemd calendar-event documentation](https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html)
for the interface on which it is based and
[example_timer_scheduler.nim](examples/example_timer_scheduler.nim) for a
runnable example.

### One-Shot Jobs

Use `at` inside a `metronome` or `scheduler` block to schedule a job once at a
specific `DateTime`. One-shot jobs stop after their first launch. If a pending
one-shot job is paused and resumed before or after its scheduled time, it
remains pending and launches once.

```nim
import metronome, times, asyncdispatch

metronome:
  at(time=now()+initDuration(minutes=5), id="warm-cache", async=true):
    echo("warming cache")
```

Direct `initBeater` calls can also schedule a single run:

```nim
let beater = initBeater(
  now()+initDuration(minutes=5),
  proc(): Future[void] {.async.} = discard,
  id="warm-cache"
)
```

### Throttling

By default, only one instance of the job is to be scheduled at the same time.
If a job hasn't finished but the next run time has come, the next job will
not be scheduled. That occurrence is skipped; interval cadence advances from
its nominal time without queuing a backlog. Finished job futures free capacity.

You can allow more instances by specifying `throttle=`. For example:

```nim
import metronome, times, asyncdispatch, os

metronome:
  every(seconds=1, id="tick", throttle=2):
    echo("tick", now())
    sleep(2000)

  every(seconds=1, id="async tick", async=true, throttle=2):
    echo("async tick", now())
    await sleepAsync(4000)
```

### Customize Scheduler

Sometimes, you want to run the scheduler in parallel with other libraries.
In this case, you can create your own scheduler by macro `scheduler` and
start it later.

`start()` starts the fire loops and returns without waiting for jobs to finish.
The scheduler's `waitFor()` also waits only for startup. Keep the event loop
running to execute pending jobs; `serve()` does this with a blocking loop.
Start each scheduler once: repeated calls start additional fire loops.

Below is an example showing how to run Metronome concurrently with the Prologue
web framework in one process. The scheduled job uses a GC-managed file logger,
so it runs on the shared async event-loop thread.

```nim
import std/[asyncdispatch, logging, times]
import metronome, prologue

let fileLogger = newFileLogger("messages.log", mode=fmAppend)

scheduler mySched:
  every(seconds=1, id="tick", async=true):
    let tickTime = now()
    echo("tick, seconds=1 ", tickTime)
    fileLogger.log(lvlInfo, "1 second tick: ", tickTime)

proc hello*(ctx: Context) {.async.} =
  resp "<h1>Hello, Prologue! It's alive!</h1>"

proc main() {.async.} =
  # Start the scheduler in the background of the async event loop
  asyncCheck mySched.start()

  # Keep Prologue and Metronome on the same async dispatcher. The default
  # blocking app.run() uses HTTPX worker threads and does not poll this loop.
  let settings = prologue.newSettings()
  var app = newApp(settings = settings)
  app.addRoute("/", hello)
  await app.runAsync()

when isMainModule:
  waitFor main()
```

The logger appends to `messages.log` in the process working directory. Prologue's
default HTTPX backend should use `runAsync()` as above so the main dispatcher
continues to run Metronome jobs. Run the example with:

```bash
nim c --threads:on -r examples/example_prologue.nim
```

An application that intentionally retains the blocking `app.run()` form can
instead select Prologue's standard async HTTP backend. For a Nimble binary
package like the test project, use:

```bash
nimble run -d:usestd
```

### Set Start Time and End Time

`startTime` controls the initial interval anchor. Custom schedules, including
calendar timers, query just before a future `startTime` to include an occurrence
exactly at that bound. Cron always queries from the current time and does not
use `startTime` as a lower bound. One-shot constructors take their deadline as
`time` instead of accepting a separate range.

`endTime` is an inclusive upper bound on both the nominal occurrence and the
effective deadline after interval jitter. These are schedule bounds; a late
dispatch or a running job can extend beyond `endTime`.

For example,

```nim
import metronome, times

scheduler demoSetRange:
  every(
    seconds=1,
    id="tick",
    startTime=dateTime(2026, mJan, 1, 0, 0, 0, 0, utc()),
    endTime=now()+initDuration(seconds=10)
  ):
    echo("tick", now())

when isMainModule:
  demoSetRange.serve()
```

Parameters `startTime` and `endTime` can be used independently. When omitted,
`startTime` defaults to construction time and there is no upper bound. The
blocking `serve()` loop stays alive after the range ends; use the startup and
event-loop integration described in [Customize Scheduler](#customize-scheduler)
when your application controls shutdown.

### Runnable Examples

The examples are the runnable counterparts to the snippets in this guide:

* [example_getting_started.nim](examples/example_getting_started.nim) is the
  complete introductory example shown above.
* [example_basic_intervals.nim](examples/example_basic_intervals.nim) covers
  sync and async intervals, throttling, and a bounded time window.
* [example_async_jobs.nim](examples/example_async_jobs.nim) demonstrates a
  finite async scheduler run.
* [example_blocking.nim](examples/example_blocking.nim) combines thread-backed
  and async interval and cron jobs.
* [example_cron_scheduler.nim](examples/example_cron_scheduler.nim) covers
  lists and the weekday `#` and `L` forms.
* [example_cron_timezone.nim](examples/example_cron_timezone.nim) demonstrates
  cron scheduling with named IANA timezones.
* [example_timer_scheduler.nim](examples/example_timer_scheduler.nim)
  demonstrates Systemd-style `OnCalendar` timers with named timezones and
  microsecond calendar targets.
* [example_firetime_calculations.nim](examples/example_firetime_calculations.nim)
  previews interval alignment, an inclusive end bound, and cron using fixed UTC
  inputs, without starting jobs.
* [example_one_shot.nim](examples/example_one_shot.nim) runs one async job once.
* [example_prologue.nim](examples/example_prologue.nim) shows async integration
  with Prologue and a file logger, and requires Prologue in addition to
  Metronome.

Compile a standalone example with threads enabled, for example:

```bash
nim c --threads:on -r examples/example_async_jobs.nim
```

### Calculate Next Run Times

Use `fireTime(prev, current)` to compute a candidate from the beater's current
schedule fields and explicit time inputs without starting a scheduler. This
preview does not check pause/stop state or throttle capacity, launch jobs, or
update `lastRun` or `nextRun`.
Built-in nominal calculations are deterministic for fixed schedule and time
inputs. Interval jitter samples randomness, and custom callbacks can capture
mutable state, so repeated `fireTime` calls can return different results.
An interval query samples once when its nominal occurrence passes the upper
bound check and its jitter window measures at least one millisecond. It does
not reserve that deadline: `nextRun` reports the runtime's pending deadline,
while a later preview or execution samples independently.

```nim
import metronome, times, options, asyncdispatch

proc noop(): Future[void] {.async.} = discard

let current = dateTime(2026, mJan, 1, 12, 35, 0, 0, utc())
let beater = initBeater(
  initTimeInterval(minutes=10),
  noop,
  startTime=some(dateTime(2026, mJan, 1, 12, 0, 0, 0, utc()))
)

echo beater.fireTime(none(DateTime), current).get()
```

This prints `2026-01-01T12:40:00Z`. The complete
[fire-time example](examples/example_firetime_calculations.nim) also previews
an inclusive interval window and a cron occurrence:

```bash
nim c --threads:on -r examples/example_firetime_calculations.nim
```

```text
Interval next run: 2026-01-01T12:40:00Z
Windowed next run: 2026-01-01T12:40:00Z
Cron next run: 2027-01-01T00:00:00Z
```

Here `none(DateTime)` requests initial alignment: a past interval anchor uses
the interval's length in whole milliseconds at `startTime` to find the next
cadence boundary. An exact past boundary advances a full interval. Supplying
`some(previousNominalTime)` instead adds the original `TimeInterval` to that
occurrence, even if the result is behind `current`. Calendar months and years
retain Nim's calendar arithmetic; jitter and job duration do not shift cadence.

Cron queries from `current`, independently of `startTime` and the previous
occurrence, and returns in `current`'s timezone. Custom callbacks return the
first instant strictly after their input, or `none(DateTime)` when exhausted.
A future custom `startTime` queries one nanosecond before that bound to allow
an occurrence exactly at it. Custom and one-shot targets retain their supplied
precision and timezone; a pending one-shot returns its deadline even if overdue.
Candidates exactly at `endTime` are allowed. An absent candidate or one outside
the upper bound returns `none(DateTime)`.

### Error Handling

Schedulers keep running when a scheduled async job fails. Failed job futures are
recorded on the beater and can be passed to either a scheduler-level error
handler or a job-level error handler. Job-level handlers take precedence.
Error handlers are supported for async jobs only; thread-backed sync jobs do not
propagate exceptions through their returned futures.

```nim
import metronome, asyncdispatch, times

proc handleSchedulerError(fut: Future[void]) {.gcsafe.} =
  echo("job failed: ", fut.readError().msg)

proc handleJobError(fut: Future[void]) {.gcsafe.} =
  echo("specific job failed: ", fut.readError().msg)

let sched = initScheduler(newSettings(errorHandler=handleSchedulerError))
sched.register(initBeater(
  initTimeInterval(seconds=1),
  proc(): Future[void] {.async.} =
    raise newException(ValueError, "boom"),
  id="failing-job",
  errorHandler=handleJobError
))

asyncCheck sched.start()
```

The `every`, `cron`, `timer`, and `at` DSL commands support job-level handlers
on async jobs using `onError=`.

```nim
scheduler sched:
  every(seconds=1, id="failing-job", async=true, onError=handleJobError):
    raise newException(ValueError, "boom")
```

Use `lastError(id)`, `lastErrorAt(id)`, and `failures(id)` to inspect failure
state for a registered job. Invocation errors and nil job futures follow the
same failure-reporting path. Catchable errors raised by an error handler are
logged and contained. Already-running jobs still report completion or failure
after pause or stop.

### Interval Jitter

Interval jobs can add a non-negative random delay to each computed run time with
`jitter`. This is useful when many jobs or application instances would otherwise
launch at the same instant. Jitter is supported only for interval schedules.

```nim
import metronome, asyncdispatch, times

scheduler sched:
  every(minutes=5, id="spread-out", async=true, jitter=initTimeInterval(seconds=30)):
    echo("tick ", now())
```

Each five-minute nominal occurrence in this example receives a random delay
from `0` to `30` seconds. Direct `initBeater` calls accept the same `jitter`
parameter:

```nim
let beater = initBeater(
  initTimeInterval(minutes=5),
  proc(): Future[void] {.async.} = discard,
  id="spread-out",
  jitter=initTimeInterval(seconds=30)
)
```

The jitter window uses `TimeInterval` arithmetic at each nominal occurrence,
then samples an inclusive whole-millisecond delay. Non-positive measured windows
add no delay. Nominal cadence stays unchanged after launches and throttled
occurrences. Both the nominal occurrence and the jittered deadline must be at
or before `endTime`.

### Job Controls

Schedulers can pause, resume, and stop registered jobs by id. Anonymous jobs can
still be registered, but ID-based controls only work when an id uniquely
identifies one registered job.

`pause(id)` prevents future launches for that job. Already-running job futures
are not cancelled. While paused, `nextRun(id)` is cleared; when resumed, interval
jobs schedule from the current time instead of replaying every interval missed
during the pause.

Pending one-shot jobs survive a pause, including when their deadline passes
before resume, and stop after exactly one launch. Dispatch rechecks the clock
after waiting, including for positive deadlines less than a millisecond away.

`resume(id)` returns a paused job to normal scheduling. `stop(id)` permanently
stops one job and clears its next run time. `stopAll()` permanently stops all
registered jobs. Active async jobs and worker threads can finish after either
stop operation. The ID-based control procs return `true` when exactly one job
matches the id and `false` when the id is missing, empty, or ambiguous.

```nim
import metronome, asyncdispatch, times

let sched = initScheduler(newSettings())
sched.register(initBeater(initTimeInterval(seconds=10), proc(): Future[void] {.async.} = discard, id="tick"))

discard sched.pause("tick")
discard sched.resume("tick")
discard sched.stop("tick")
sched.stopAll()
```

### Job Introspection

Schedulers expose runtime state for dashboards, logs, tests, and health checks.
Like controls, ID-based introspection only returns job data when exactly one
registered job has that non-empty id. Missing, empty, anonymous, or duplicate ids
return `none(...)`, `nil`, or `0` depending on the accessor.

```nim
import metronome, asyncdispatch, times, options

let sched = initScheduler(newSettings())
sched.register(initBeater(initTimeInterval(seconds=10), proc(): Future[void] {.async.} = discard, id="tick"))

echo sched.listJobs()

echo sched.jobState("tick")
echo sched.lastRun("tick")
echo sched.nextRun("tick")
echo sched.lastError("tick")
echo sched.lastErrorAt("tick")
echo sched.failures("tick")
echo sched.runningCount("tick")
```

`listJobs()` returns all non-empty registered ids, including duplicates. Use
`jobState(id)` to inspect whether a job is running, paused, or stopped.
`lastRun(id)` reports the actual launch timestamp and `nextRun(id)` the pending
effective deadline, both as `Option[DateTime]`. `nextRun` is empty before
execution plans an occurrence, while paused or stopped, and after exhaustion;
it is not calculated on demand. Exhaustion does not itself change a recurring
job's lifecycle state to stopped. `lastError(id)` returns the most recent
exception or `nil`; `lastErrorAt(id)` and `failures(id)`
report when and how often the job failed. `runningCount(id)` reports currently
running job futures for that scheduled job.

## Changelog

See [CHANGELOG.md](CHANGELOG.md#unreleased) for unreleased changes.

Released:
* v0.5.1, 23 Aug, 2026, Clarify scheduler architecture, add section about scheduler and direct constructors.
* v0.5.0, 5 Aug, 2026, Marked the project as beta and added development and release version safeguards to CI.
* v0.4.3, 16 Jul, 2026, Add systemd-style calendar timers, embedded IANA timezone support, and CI-generated documentation.
* v0.4.0, 11 Jul, 2026, Renamed library to Metronome, updated all references, documentation and examples
* v0.3.1, 10 Jul, 2026, Add async job error handling, job lifecycle and introspection APIs, one-shot and timezone-aware scheduling, interval jitter, and expanded tests, CI, and documentation.
* v0.3.0, 8 Jul, 2026, Upgrade to Nim 2.2.10, resolve warnings, fix weekday index/last bugs, expand tests, and add CI coverage.
* v0.2.0, 22 Jul, 2021, New feature: cron.
* v0.1.2, 8 Jul, 2021, Bugfix: the first job schedule should be after startTime.
* v0.1.1, update metadata.
* v0.1.0, initial release.

## Development

Day-to-day changes target `development`; `master` tracks released versions.
Immediately after each release, the package version on `development` is bumped
to the next planned version so an unreleased checkout cannot identify itself as
the previous release. CI tests pushes and pull requests for both branches and
validates their release/version rules.

### Running Tests

To run the automated unit tests:

```bash
nimble test
```

`tests/test_schedule_calculation.nim` tests the private nominal calculator with
fixed dates and explicit inputs, without job futures or an event loop. Run it
alone with `nim c -r tests/test_schedule_calculation.nim`. Beater tests retain
public calculation compatibility and controlled jitter checks alongside
published-deadline waiting, pause/resume, active-job completion, throttling, and
failure handling. Scheduler tests also execute generated async callbacks using
global GC-managed state and verify startup and failure reporting after stopping.
[PROJECT_STATE.md](PROJECT_STATE.md)
records the current calculation and execution contracts for maintainers.

### Code Coverage

Install `lcov` and `genhtml`, then run the canonical coverage task:

```bash
nimble coverage
```

The task runs all six suites with separate compiler caches and includes the
private nominal calculator in source coverage. It generates
`coverage_html/index.html` and updates `docs/coverage.svg`. CI invokes
the same task, requires at least 80% line coverage, and publishes the generated
badge with the documentation. Generated coverage files are not committed.

### Documentation

To generate the HTML documentation locally:

```bash
nimble docs
```

This compiles the root scheduler documentation and the optional named-timezone
and calendar-timer modules, then outputs the generated files directly into the
ignored `docs/` folder. You can open `docs/metronome.html` for the scheduler API,
`docs/timezones.html` for named IANA timezone support, or `docs/timers.html`
for systemd-style calendar timers. On pushes to `master`, CI deploys this folder
to GitHub Pages as an artifact instead of committing generated files to the
repository. The private calculator is omitted from the API index; its generated
implementation page remains available through module import links.

### Updating the embedded timezone database

The maintainer-only updater pins and verifies matching IANA `tzdata` and
`tzcode` releases. It builds that release's `zic`; it never silently uses the
host's installed `zic`.

```bash
nim r tools/update_timezones.nim -- 2026c
nim r tools/update_timezones.nim -- 2026c --check
```

The updater requires `curl`, `sha256sum`, `tar`, `make`, and a C99 compiler.
Applications do not need these tools. Updating the pin requires reviewing and
changing both committed SHA-256 checksums in the updater.

## License

Metronome is licensed under the MIT License.

## Attributions

* [@soasme](https://github.com/soasme) originally created the scheduler base of this library ([nim-schedules](https://github.com/soasme/nim-schedules)).
* [@GULPF](https://github.com/GULPF) originally created the timezones base of this library ([timezones](https://github.com/GULPF/timezones)).

Portions of both libraries were adapted under the MIT License.
