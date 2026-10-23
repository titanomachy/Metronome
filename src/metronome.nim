## # Metronome
##
## A Nim scheduler library for interval, cron, timer, and one-shot jobs.
##
## Internal helpers calculate nominal occurrences from explicit schedule and
## time inputs. Beaters own jitter, waiting, lifecycle state, and job execution.
## The calculation helpers are not part of the supported public API.
##
## ## Schedule By Every
##
## Example usage::
##
##     import metronome, times, asyncdispatch
##
##     metronome:
##       every(seconds=1, id="tick", async=true):
##         echo("async tick ", now())
##         await sleepAsync(2000)
##       every(seconds=1, id="sync tick"):
##         echo("sync tick ", now())
##
## The code enables you:
##
## * Schedule an async proc every second.
## * Schedule a thread-backed proc every second.
##
## Run::
##
##     nim c --threads:on -r examples/example_basic_intervals.nim
##
## Note:
##
## * Compile applications that import metronome with --threads:on. Jobs without
##   async=true run in worker threads and must satisfy Nim's thread and GC-safety
##   rules. Async jobs run on the event loop and should not make blocking calls.
## * Exceptions from thread-backed jobs are not propagated through job futures.
## * The library schedules all jobs at a regular interval, but it'll be impacted by your system load.
##
## ## Schedule By Cron
##
## You can set minute, hour, day_of_month, month, day_of_week, and year in the
## cron() call. Omitted fields default to `*`, and scheduling has one-minute
## resolution.
##
## Supported field ranges:
##
## * minute: 0-59
## * hour: 0-23
## * day_of_month: 1-31
## * month: 1-12 or jan-dec
## * day_of_week: 1-7 or mon-sun, where Monday is 1
## * year: 1970-9999
##
## Fields are case-insensitive. All fields accept `*`, comma-separated lists,
## inclusive ranges, and steps such as `*/5`, `2/3`, or `1-10/2`.
## day_of_month also accepts `L` or `last` for the last day of the month.
## day_of_week accepts `dL` for the last named weekday and `d#n` for the nth
## named weekday, such as `friL` and `mon#3`.
##
## When both day_of_month and day_of_week are restricted, a match on either
## field is selected. The parser recognizes `?` and `W`, but the next-run
## evaluator does not implement them. Direct newCron calls expose `second`, but
## the current next-run calculation does not evaluate it.
##
## Example usage::
##
##     import metronome, times, asyncdispatch
##     metronome:
##       cron(minute="*/1", hour="*", day_of_month="*", month="*", day_of_week="*", id="tick"):
##         echo("tick", now())
##       cron(minute="*/1", hour="*", day_of_month="*", month="*", day_of_week="*", id="atick", async=true):
##         echo("tick", now())
##         await sleepAsync(3000)
##
## The code enables you:
##
## * Schedule thread proc every minute.
## * Schedule async proc every minute.
## * Pass timezone=utc() or another Timezone to evaluate cron fields in that
##   zone.
##
## Run::
##
##     nim c --threads:on -r examples/example_cron_scheduler.nim
##
## ## Named IANA Timezones
##
## Import ``metronome/timezones`` separately to resolve an embedded IANA name.
## The optional database is not included when an application imports only
## ``metronome``::
##
##     import metronome, metronome/timezones
##     import asyncdispatch, times
##
##     let zone = namedTimezone("Europe/Amsterdam")
##
##     scheduler localSched:
##       cron(hour="9", minute="0", timezone=zone, async=true):
##         echo now().inZone(zone)
##
## Cron fields stay at the requested local wall-clock hour across DST changes.
## See the generated ``metronome/timezones`` module documentation for database
## version reporting, supported-name lookup, and local-time edge-case behavior.
##
## ## Schedule by Timer
##
## Import ``metronome/timers`` separately to schedule jobs with systemd-style
## calendar expressions. The timer parser and embedded timezone database stay
## out of applications that import only ``metronome``::
##
##     import metronome
##     import metronome/timers
##
##     scheduler timerSched:
##       timer(
##         onCalendar="*-*-* 02:00:00 Europe/Amsterdam",
##         id="nightly",
##         async=true
##       ):
##         echo "Running nightly"
##
## Syntax: ``Year-Month-Day Hour:Minute:Second TimeZone``.
## Fractional seconds retain one-microsecond calendar resolution, but event-loop
## dispatch remains best-effort and normally has millisecond-scale accuracy.
## See the generated ``metronome/timers`` documentation for supported systemd
## forms and compatibility boundaries.
##
## Note:
##
## * Compile applications with --threads:on.
## * The library schedules all jobs at a regular interval, but it'll be impacted by your system load.
##
## ## Schedule Once
##
## Use at(time=...) inside a metronome or scheduler block to schedule a job one time.::
##
##     import metronome, times, asyncdispatch
##
##     metronome:
##       at(time=now()+initDuration(minutes=5), id="warm-cache", async=true):
##         echo("warming cache")
##
## One-shot jobs stop after their first launch.
##
## ## Throttling
##
## By default, only one instance of the job is to be scheduled at the same time. If a job hasn't finished but the next run time has come, the next job will not be scheduled.
## Skipped occurrences advance nominal interval cadence without queuing a backlog.
## Finished job futures free capacity for later occurrences.
##
## You can allow more instances by specifying `throttle=`. For example::
##
##     import metronome, times, asyncdispatch
##
##     metronome:
##       every(seconds=1, id="async tick", throttle=2, async=true):
##         echo("async tick ", now())
##         await sleepAsync(2000)
##       every(seconds=1, id="tick", throttle=2):
##         echo("sync tick ", now())
##
##
## ## Customize Scheduler
##
## Sometimes, you want to run the scheduler in parallel with other libraries. In this case, you can create your own scheduler by macro scheduler and start it later.
## start() starts fire loops and returns without waiting for jobs to finish.
## The scheduler's waitFor() also waits only for startup; keep the event loop
## running for pending jobs, or use the blocking serve() loop. Start each
## scheduler once: repeated calls start additional fire loops.
##
## Below is an example of running Metronome and Prologue in one process.::
##
##     import std/[asyncdispatch, logging, times]
##     import metronome, prologue
##
##     let fileLogger = newFileLogger("messages.log", mode=fmAppend)
##
##     scheduler mySched:
##       every(seconds=1, id="tick", async=true):
##         let tickTime = now()
##         echo("tick, seconds=1 ", tickTime)
##         fileLogger.log(lvlInfo, "1 second tick: ", tickTime)
##
##     proc hello*(ctx: Context) {.async.} =
##       resp "<h1>Hello, Prologue! It's alive!</h1>"
##
##     proc main() {.async.} =
##       asyncCheck mySched.start()
##
##       let settings = prologue.newSettings()
##       var app = newApp(settings=settings)
##       app.addRoute("/", hello)
##       await app.runAsync()
##
##     when isMainModule:
##       waitFor main()
##
## ## Set Start Time and End Time
##
## You can limit the schedules running in a designated range of time by specifying startTime and endTime.
##
## For example::
##
##     import metronome, times, asyncdispatch, os
##
##     scheduler demoSetRange:
##       every(
##         seconds=1,
##         id="tick",
##         startTime=initDateTime(2019, 1, 1),
##         endTime=now()+initDuration(seconds=10)
##       ):
##         echo("tick", now())
##
##     when isMainModule:
##       waitFor demoSetRange.start()
##
## Parameters startTime and endTime can be used independently. For example, you can set startTime only, or set endTime only.
##
## ## Calculate Next Run Times
##
## Use fireTime to inspect the next scheduled run without starting a scheduler.
## Built-in nominal calculations are deterministic for fixed schedule and time
## inputs. Interval jitter samples randomness, and custom callbacks may capture
## mutable state, so repeated fireTime calls can return different results.
## Each eligible interval query samples the beater's RNG once. It does not
## reserve that deadline: nextRun reports the runtime's pending deadline, while
## a later preview or execution samples independently.
##
## Example:
##
##     import metronome, times, options, asyncdispatch
##
##     proc noop(): Future[void] {.async.} = discard
##
##     let current = dateTime(2026, mJan, 1, 12, 35, 0, 0, utc())
##     let beater = initBeater(
##       initTimeInterval(minutes=10),
##       noop,
##       startTime=some(dateTime(2026, mJan, 1, 12, 0, 0, 0, utc()))
##     )
##
##     echo beater.fireTime(none(DateTime), current).get()
##
## With no previous occurrence, intervals align using their whole-millisecond
## length at startTime; an exact past cadence boundary advances a full interval.
## With a previous nominal occurrence, the original calendar-relative interval
## is added to it, even if the result is overdue. Jitter and job duration do not
## shift that nominal cadence.
##
## Cron queries from current independently of startTime and the prior occurrence,
## and returns in current's timezone. Custom callbacks return the first instant
## strictly after their input or none(DateTime) when exhausted. A future custom
## startTime queries one nanosecond before that bound to include it. Custom and
## one-shot targets retain their supplied precision and timezone; a pending
## one-shot returns its deadline even when overdue. endTime is inclusive.
##
## ## Error Handling
##
## Schedulers keep running when a scheduled async job fails. Failed job futures
## are recorded on the beater and can be passed to either a scheduler-level error
## handler or a job-level error handler. Job-level handlers take precedence.
## Error handlers are supported for async jobs only; thread-backed sync jobs do
## not propagate exceptions through their returned futures.
##
## Example usage::
##
##     import metronome, asyncdispatch, times
##
##     proc handleSchedulerError(fut: Future[void]) {.gcsafe.} =
##       echo("job failed: ", fut.readError().msg)
##
##     proc handleJobError(fut: Future[void]) {.gcsafe.} =
##       echo("specific job failed: ", fut.readError().msg)
##
##     let sched = initScheduler(newSettings(errorHandler=handleSchedulerError))
##     sched.register(initBeater(
##       initTimeInterval(seconds=1),
##       proc(): Future[void] {.async.} =
##         raise newException(ValueError, "boom"),
##       id="failing-job",
##       errorHandler=handleJobError
##     ))
##
##     asyncCheck sched.start()
##
## The every and cron macros also support job-level handlers on async jobs
## using onError=::
##
##     scheduler sched:
##       every(seconds=1, id="failing-job", async=true, onError=handleJobError):
##         raise newException(ValueError, "boom")
##
## Use lastError(id), lastErrorAt(id), and failures(id) to inspect failure state
## for a registered job.
##
## ## Interval Jitter
##
## Interval jobs can add a non-negative random delay to each computed run time
## with jitter. This is useful when many jobs or application instances would
## otherwise launch at the same instant. Jitter is only supported for interval
## schedules, not cron schedules.
##
## Example usage::
##
##     import metronome, asyncdispatch, times
##
##     scheduler sched:
##       every(minutes=5, id="spread-out", async=true, jitter=initTimeInterval(seconds=30)):
##         echo("tick ", now())
##
## Direct initBeater calls accept the same jitter parameter::
##
##     let beater = initBeater(
##       initTimeInterval(minutes=5),
##       proc(): Future[void] {.async.} = discard,
##       id="spread-out",
##       jitter=initTimeInterval(seconds=30)
##     )
##
## The jitter window uses TimeInterval arithmetic at each nominal occurrence,
## then samples an inclusive whole-millisecond delay. Non-positive measured
## windows add no delay. Nominal cadence stays unchanged after launches and
## throttled occurrences. Both the nominal occurrence and the jittered deadline
## must be at or before endTime.
##
## ## Job Controls
##
## Schedulers can pause, resume, and stop registered jobs by id. Anonymous jobs
## can still be registered, but ID-based controls only work when an id uniquely
## identifies one registered job.
##
## pause(id) prevents future launches for that job. Already-running job futures
## are not cancelled. While paused, nextRun(id) is cleared; when resumed,
## interval jobs schedule from the current time instead of replaying every
## interval missed during the pause.
##
## Pending one-shots survive pauses even if their deadline passes before resume,
## and stop after exactly one launch. Dispatch rechecks the clock after waiting,
## including for positive deadlines less than a millisecond away.
##
## resume(id) returns a paused job to normal scheduling. stop(id) permanently
## stops one job and clears its next run time. stopAll() permanently stops all
## registered jobs. Active async jobs and worker threads can finish after either
## stop operation. The ID-based control procs return true when exactly one job
## matches the id and false when the id is missing, empty, or ambiguous.
##
## Example usage::
##
##     import metronome, asyncdispatch, times
##
##     let sched = initScheduler(newSettings())
##     sched.register(initBeater(
##       initTimeInterval(seconds=10),
##       proc(): Future[void] {.async.} = discard,
##       id="tick"
##     ))
##
##     discard sched.pause("tick")
##     discard sched.resume("tick")
##     discard sched.stop("tick")
##     sched.stopAll()


import metronome/scheduler
import metronome/cron/cron

export logger
export BeaterAsyncProc
export BeaterThreadProc
export NextRunProc
export Throttler
export initThrottler
export throttled
export submit
export BeaterKind
export BeaterState
export Beater
export `$`
export initBeater
export id
export state
export lastRun
export nextRun
export lastError
export lastErrorAt
export failures
export runningCount
export pause
export resume
export stop
export fireTime
export fire
export JobErrorHandler
export Settings
export newSettings
export Scheduler
export initScheduler
export register
export listJobs
export jobState
export stopAll
export idle
export start
export serve
export waitFor
export scheduler
export metronome
export Cron
export newCron
export getNext
