# nim-schedules

[![CI](https://github.com/titanomachy/nim-schedules/actions/workflows/ci.yml/badge.svg)](https://github.com/titanomachy/nim-schedules/actions/workflows/ci.yml)
[![Coverage](docs/coverage.svg)](https://github.com/titanomachy/nim-schedules/actions)

[@soasme](https://github.com/soasme) originally created the base of this library, thank you Ju. You can find it [here](https://github.com/soasme/nim-schedules).

A Nim scheduler library that lets you kick off jobs at regular intervals.

Read the [documentation](https://titanomachy.github.io/nim-schedules/schedules.html).

Features:

* Simple to use API for scheduling jobs.
* Support scheduling both async and sync procs.
* Interval, cron, and one-shot scheduling.
* Timezone-aware cron schedules.
* Job-level and scheduler-level async error handling.
* Pause, resume, stop, and inspect registered jobs by id.
* Optional interval jitter to spread out job launches.
* Lightweight and zero dependencies.

## Getting Started

```bash
$ nimble install https://github.com/titanomachy/nim-schedules
```

## Usage

```nim
# File: scheduleExample.nim
import schedules, times, asyncdispatch

schedules:
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
nim c --threads:on -r scheduleExample.nim
```

Note:

* Don't forget **`--threads:on`** when compiling your application.
* The library schedules all jobs at a regular interval, but it'll be impacted
  by your system load.

## Advance Usages

### Cron

You can use `cron` to schedule jobs using cron-like syntax.

```nim
import schedules, times, asyncdispatch

schedules:
  cron(minute="*/1", hour="*", day_of_month="*", month="*", day_of_week="*", id="tick"):
    echo("tick", now())

  cron(minute="*/1", hour="*", day_of_month="*", month="*", day_of_week="*", id="atick", async=true):
    echo("tick", now())
    await sleepAsync(3000)
```

1. Schedule thread proc every minute.
2. Schedule async proc every minute.

Cron schedules can also be evaluated in a specific Nim `Timezone` by passing
`timezone=`.

```nim
import schedules, times, asyncdispatch, options

schedules:
  cron(hour="9", minute="0", id="utc-daily", async=true, timezone=utc()):
    echo("09:00 UTC ", now())
```

Direct `initBeater` calls accept `timezone=some(myTimezone)`.

### One-Shot Jobs

Use `at` inside a `schedules` or `scheduler` block to schedule a job once at a
specific `DateTime`. One-shot jobs stop after their first launch. If a pending
one-shot job is paused and resumed before or after its scheduled time, it
remains pending and launches once.

```nim
import schedules, times, asyncdispatch

schedules:
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
not be scheduled.

You can allow more instances by specifying `throttle=`. For example:

```nim
import schedules, times, asyncdispatch, os

schedules:
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

Below is an example showing how to run `nim-schedules` concurrently with the Prologue web framework in one process.

```nim
import times, asyncdispatch, schedules, prologue

scheduler mySched:
  every(seconds=1, id="sync tick"):
    echo("sync tick, seconds=1 ", now())

proc hello*(ctx: Context) {.async.} =
  resp "<h1>Hello, Prologue! It's alive!</h1>"

proc main() =
  # Start the scheduler in the background of the async event loop
  asyncCheck mySched.start()

  # Set up and run the Prologue web application
  let settings = prologue.newSettings()
  var app = newApp(settings = settings)
  app.addRoute("/", hello)
  app.run()

when isMainModule:
  main()
```

### Set Start Time and End Time

You can limit the schedules running in a designated range of time by specifying
`startTime` and `endTime`.

For example,

```nim
import schedules, times, asyncdispatch, os

scheduler demoSetRange:
  every(
    seconds=1,
    id="tick",
    startTime=initDateTime(2019, 1, 1),
    endTime=now()+initDuration(seconds=10)
  ):
    echo("tick", now())

when isMainModule:
  waitFor demoSetRange.start()
```

Parameters `startTime` and `endTime` can be used independently. For example,
you can set startTime only, or set endTime only.

### Calculate Next Run Times

Use `fireTime` to inspect the next scheduled run without starting a scheduler.
This is useful for tests, dashboards, and checking interval or cron behavior
deterministically.

```nim
import schedules, times, options, asyncdispatch

proc noop(): Future[void] {.async.} = discard

let current = dateTime(2026, mJan, 1, 12, 35, 0, 0, utc())
let beater = initBeater(
  initTimeInterval(minutes=10),
  noop,
  startTime=some(dateTime(2026, mJan, 1, 12, 0, 0, 0, utc()))
)

echo beater.fireTime(none(DateTime), current).get()
```

### Error Handling

Schedulers keep running when a scheduled async job fails. Failed job futures are
recorded on the beater and can be passed to either a scheduler-level error
handler or a job-level error handler. Job-level handlers take precedence.
Error handlers are supported for async jobs only; thread-backed sync jobs do not
propagate exceptions through their returned futures.

```nim
import schedules, asyncdispatch, times

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

The `every` and `cron` macros also support job-level handlers on async jobs
using `onError=`.

```nim
scheduler sched:
  every(seconds=1, id="failing-job", async=true, onError=handleJobError):
    raise newException(ValueError, "boom")
```

Use `lastError(id)`, `lastErrorAt(id)`, and `failures(id)` to inspect failure
state for a registered job.

### Interval Jitter

Interval jobs can add a non-negative random delay to each computed run time with
`jitter`. This is useful when many jobs or application instances would otherwise
launch at the same instant. Jitter is only supported for interval schedules, not
cron schedules.

```nim
import schedules, asyncdispatch, times

scheduler sched:
  every(minutes=5, id="spread-out", async=true, jitter=initTimeInterval(seconds=30)):
    echo("tick ", now())
```

The example above runs every five minutes plus a random delay from `0` to `30`
seconds. Direct `initBeater` calls accept the same `jitter` parameter:

```nim
let beater = initBeater(
  initTimeInterval(minutes=5),
  proc(): Future[void] {.async.} = discard,
  id="spread-out",
  jitter=initTimeInterval(seconds=30)
)
```

### Job Controls

Schedulers can pause, resume, and stop registered jobs by id. Anonymous jobs can
still be registered, but ID-based controls only work when an id uniquely
identifies one registered job.

`pause(id)` prevents future launches for that job. Already-running job futures
are not cancelled. While paused, `nextRun(id)` is cleared; when resumed, interval
jobs schedule from the current time instead of replaying every interval missed
during the pause.

`resume(id)` returns a paused job to normal scheduling. `stop(id)` permanently
stops one job and clears its next run time. `stopAll()` permanently stops all
registered jobs. The ID-based control procs return `true` when exactly one job
matches the id and `false` when the id is missing, empty, or ambiguous.

```nim
import schedules, asyncdispatch, times

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
import schedules, asyncdispatch, times, options

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
`lastRun(id)` and `nextRun(id)` return `Option[DateTime]` values. `lastError(id)`
returns the most recent exception or `nil`; `lastErrorAt(id)` and `failures(id)`
report when and how often the job failed. `runningCount(id)` reports currently
running job futures for that scheduled job.

## ChangeLog

Released:

* v0.3.0, 8 Jul, 2026, Upgrade to Nim 2.2.10, resolve warnings, fix weekday index/last bugs, expand tests, and add CI coverage.
* v0.2.0, 22 Jul, 2021, New feature: cron.
* v0.1.2, 8 Jul, 2021, Bugfix: the first job schedule should be after startTime.
* v0.1.1, update metadata.
* v0.1.0, initial release.

## Development

### Running Tests

To run the automated unit tests:

```bash
nimble test
```

### Code Coverage

To run the tests with code coverage instrumentation:

```bash
nimble coverage
```

This will run all tests and compile intermediate C files in `nimcache/`. If you have `lcov` and `genhtml` installed, you can generate an HTML coverage report:

```bash
lcov --ignore-errors inconsistent,unused,mismatch,missing,source,empty,gcov --capture --directory nimcache --output-file coverage.info
lcov --ignore-errors inconsistent,unused,mismatch,missing,source,empty,gcov --extract coverage.info "$PWD/src/*" --output-file coverage.info
genhtml --ignore-errors range --filter missing coverage.info --output-directory coverage_html
scripts/coverage_badge.sh coverage.info docs/coverage.svg
```

Open `coverage_html/index.html` in your browser to view the coverage report.

### Documentation

To generate the HTML documentation locally:

```bash
nimble docs
```

This compiles all docstrings in the codebase and outputs the generated files directly into the `docs/` folder. You can open `docs/schedules.html` in your browser to read the generated docs.

## License

Nim-schedules is based on MIT license.
