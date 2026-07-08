# nim-schedules

[![CI](https://github.com/titanomachy/nim-schedules/actions/workflows/ci.yml/badge.svg)](https://github.com/titanomachy/nim-schedules/actions/workflows/ci.yml)
[![Coverage](docs/coverage.svg)](https://github.com/titanomachy/nim-schedules/actions)

A Nim scheduler library that lets you kick off jobs at regular intervals.

Read the documentation [online](https://titanomachy.github.io/nim-schedules/schedules.html) or [locally](docs/schedules.html).

Features:

* Simple to use API for scheduling jobs.
* Support scheduling both async and sync procs.
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
