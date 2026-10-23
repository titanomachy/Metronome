import unittest

import times, options, asyncdispatch, strutils
import std/importutils
import metronome
import metronome/scheduler as schedulerApi
import ./compiler_probe

proc noop(): Future[void] {.async.} = discard

proc failingJob(): Future[void] {.async.} =
  raise newException(ValueError, "boom")

proc syncNoop() {.thread, gcsafe.} =
  discard

var macroErrorHandlerCalls = 0
var macroOnceCalls = 0

type MacroGcState = ref object
  calls: int

var macroGcState = MacroGcState()

proc macroErrorHandler(fut: Future[void]) {.gcsafe.} =
  discard fut.readError()
  macroErrorHandlerCalls.inc

proc macroOnceJob(): Future[void] {.async.} =
  macroOnceCalls.inc

test "Public scheduler types remain compatible through both imports":
  type ExtendedBeater = ref object of schedulerApi.Beater
    marker: int

  static:
    doAssert NextRunProc is schedulerApi.NextRunProc
    doAssert BeaterKind is schedulerApi.BeaterKind
    # Internal calculation helpers must not become public re-exports.
    doAssert not declared(intervalNextRun)
    doAssert not declared(cronNextRun)
    doAssert not declared(customNextRun)
    doAssert not declared(onceNextRun)

  let callback: schedulerApi.NextRunProc = proc(
    current: DateTime
  ): Option[DateTime] {.closure, gcsafe, raises: [].} =
    some(current + initDuration(microseconds=1))
  let publicCallback: NextRunProc = callback
  let current = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  let beater: schedulerApi.Beater = initBeater(
    publicCallback, noop, startTime=some(current)
  )
  let extended = ExtendedBeater(
    kind: schedulerApi.BeaterKind.bkInterval,
    interval: initTimeInterval(seconds=1),
    marker: 42
  )

  check beater.kind == bkCustom
  check beater.fireTime(none(DateTime), current).get() ==
    current + initDuration(microseconds=1)
  check extended of Beater
  check extended.interval == initTimeInterval(seconds=1)
  check extended.marker == 42


test "endTime":

  scheduler testEndTime:
    every(seconds=1, id="sync tick", endTime=now()+initDuration(seconds=2)):
      echo("sync tick, seconds=1 ", now())

    every(seconds=1, id="async tick", async=true, endTime=now()+initDuration(seconds=2)):
      echo("async tick, seconds=1 ", now())

  proc main(): Future[bool] {.async.} =
    await testEndTime.start()
    return true

  check (waitFor(main()))

test "Async scheduler jobs can access global GC-managed state":
  scheduler testGlobalGcState:
    every(seconds=1, id="global-gc-state", async=true):
      macroGcState.calls.inc

  check testGlobalGcState.listJobs == @["global-gc-state"]
  let before = macroGcState.calls
  let job: BeaterAsyncProc = proc(): Future[void] {.async.} =
    macroGcState.calls.inc
  let beater = initBeater(dateTime(2000, mJan, 1, 0, 0, 0, 0, utc()), job)
  waitFor beater.fire()
  waitFor sleepAsync(0)
  check macroGcState.calls == before + 1
  check beater.runningCount == 0

test "Scheduler lists and controls registered jobs":
  let scheduler = initScheduler(newSettings())
  let beater = initBeater(initTimeInterval(seconds=1), noop, id="tick")
  scheduler.register(beater)

  check scheduler.listJobs == @["tick"]
  check scheduler.jobState("tick").get == bsRunning
  check scheduler.runningCount("tick") == 0
  check scheduler.lastRun("tick").isNone
  check scheduler.nextRun("tick").isNone
  check scheduler.lastError("tick") == nil
  check scheduler.lastErrorAt("tick").isNone
  check scheduler.failures("tick") == 0

  check scheduler.pause("tick")
  check scheduler.jobState("tick").get == bsPaused

  check scheduler.resume("tick")
  check scheduler.jobState("tick").get == bsRunning

  check scheduler.stop("tick")
  check scheduler.jobState("tick").get == bsStopped

  check not scheduler.pause("missing")
  check scheduler.jobState("missing").isNone

test "Scheduler accepts nil settings":
  let scheduler = initScheduler(nil)
  let current = now()
  scheduler.register(initBeater(
    initTimeInterval(milliseconds=1),
    noop,
    startTime=some(current),
    endTime=some(current + initTimeInterval(milliseconds=5)),
    id="nil-settings"
  ))

  waitFor scheduler.start()
  waitFor sleepAsync(20)

  check scheduler.lastRun("nil-settings").isSome

test "Scheduler keeps anonymous jobs compatible and treats duplicates as ambiguous":
  let scheduler = initScheduler(newSettings())

  scheduler.register(initBeater(initTimeInterval(seconds=1), noop))
  check scheduler.listJobs == newSeq[string]()
  check not scheduler.pause("")

  scheduler.register(initBeater(initTimeInterval(seconds=1), noop, id="tick"))
  check scheduler.pause("tick")

  scheduler.register(initBeater(initTimeInterval(seconds=1), noop, id="tick"))
  check scheduler.listJobs == @["tick", "tick"]
  check not scheduler.pause("tick")
  check scheduler.jobState("tick").isNone

test "Scheduler allows thread-backed jobs with scheduler error handler":
  expect ValueError:
    discard initBeater(
      initTimeInterval(seconds=1),
      syncNoop,
      id="sync-with-handler",
      errorHandler=macroErrorHandler
    )

  let scheduler = initScheduler(newSettings(errorHandler=macroErrorHandler))
  scheduler.register(initBeater(initTimeInterval(seconds=1), syncNoop, id="sync"))
  check scheduler.listJobs == @["sync"]

test "Scheduler macro supports per-job error handler":
  macroErrorHandlerCalls = 0
  let current = now()

  scheduler testErrors:
    every(
      milliseconds=1,
      id="macro-failing",
      async=true,
      startTime=current,
      endTime=current + initDuration(milliseconds=50),
      onError=macroErrorHandler
    ):
      await failingJob()

  proc main(): Future[void] {.async.} =
    await testErrors.start()
    await sleepAsync(80)

  waitFor main()

  check macroErrorHandlerCalls > 0
  check testErrors.lastError("macro-failing") != nil
  if testErrors.lastError("macro-failing") != nil:
    check testErrors.lastError("macro-failing").msg.contains("boom")
  check testErrors.lastErrorAt("macro-failing").isSome
  check testErrors.failures("macro-failing") == macroErrorHandlerCalls

test "Scheduler macro supports interval jitter":
  scheduler testJitter:
    every(
      milliseconds=100,
      id="jittered",
      async=true,
      jitter=initTimeInterval(milliseconds=25)
    ):
      await noop()

  check testJitter.listJobs == @["jittered"]

test "Scheduler DSL forwards interval cron and one-shot parameters in both job modes":
  privateAccess(Scheduler)
  privateAccess(Beater)
  privateAccess(Throttler)
  let start = dateTime(2026, mJan, 1, 12, 1, 0, 0, utc())
  let finish = start + initDuration(minutes=2)
  let interval = initTimeInterval(
    years=1, months=2, weeks=3, days=4, hours=5, minutes=6,
    seconds=7, milliseconds=8
  )
  let jitter = initTimeInterval(milliseconds=9)
  scheduler compatibility:
    every(years=1, months=2, weeks=3, days=4, hours=5, minutes=6,
        seconds=7, milliseconds=8, jitter=jitter, startTime=start,
        endTime=finish, throttle=2, id="interval-async", async=true,
        onError=macroErrorHandler):
      macroGcState.calls.inc
      await noop()
    every(years=1, months=2, weeks=3, days=4, hours=5, minutes=6,
        seconds=7, milliseconds=8, jitter=jitter, startTime=start,
        endTime=finish, throttle=2, id="interval-thread"):
      syncNoop()
    cron(year="2026", month="1", day_of_month="1", day_of_week="Thu",
        hour="12", minute="1,2,3", timezone=utc(), startTime=start,
        endTime=finish, throttle=2, id="cron-async", async=true,
        onError=macroErrorHandler):
      macroGcState.calls.inc
      await noop()
    cron(year="2026", month="1", day_of_month="1", day_of_week="Thu",
        hour="12", minute="1,2,3", timezone=utc(), startTime=start,
        endTime=finish, throttle=2, id="cron-thread"):
      syncNoop()
    at(time=start, throttle=2, id="once-async", async=true,
        onError=macroErrorHandler):
      macroGcState.calls.inc
      await noop()
    at(time=start, throttle=2, id="once-thread"):
      syncNoop()

  check compatibility.listJobs == @[
    "interval-async", "interval-thread", "cron-async", "cron-thread",
    "once-async", "once-thread"
  ]
  let before = macroGcState.calls
  for index, beater in compatibility.beaters:
    check beater.throttler.num == 2
    check beater.startTime == start
    check (beater.errorHandler != nil) == (index mod 2 == 0)
    if beater.kind != bkOnce:
      check beater.endTime.get() == finish
    case beater.kind
    of bkInterval:
      check beater.interval == interval
      check beater.jitter == jitter
    of bkCron:
      check beater.timezone.get() == utc()
      let expected = newCron(year="2026", month="1", day_of_month="1",
        day_of_week="Thu", hour="12", minute="1,2,3")
      for query in [start - initDuration(minutes=1), start, finish]:
        let candidate = expected.getNext(query)
        let bounded = if candidate.isSome and candidate.get() > finish:
            none(DateTime)
          else: candidate
        check beater.fireTime(none(DateTime), query) == bounded
    of bkOnce:
      check beater.fireTime(none(DateTime), finish).get() == start
    else:
      check false
    # Execute each generated callback once without starting recurring fire loops.
    waitFor beater.beaterProc()
  check macroGcState.calls == before + 3

test "Core-only consumers exclude timer and named timezone dependencies":
  let checked = checkConsumer("""
import metronome
static:
  doAssert not declared(CalendarTimer)
  doAssert not declared(newTimer)
  doAssert not declared(namedTimezone)
discard newSettings()
""", dependencies=true)
  checkpoint checked.output
  check checked.exitCode == 0
  let dependencies = checked.dependencies.replace('\\', '/')
  check dependencies.contains("/metronome/scheduler.nim")
  check dependencies.contains("/metronome/private/schedule.nim")
  check dependencies.contains("/metronome/cron/cron.nim")
  check not dependencies.contains("/metronome/timers")
  check not dependencies.contains("/metronome/timezones")

test "Both DSL entry macros preserve useful compiler diagnostics":
  for entry in ["scheduler diagnosticScheduler:", "metronome:"]:
    for asyncValue in ["false", "true"]:
      let source = "import metronome\n" & entry &
        "\n  timer(onCalendar=\"daily UTC\", async=" & asyncValue &
        "):\n    discard\n"
      let checked = checkConsumer(source)
      checkpoint source & checked.output
      check checked.exitCode != 0
      check checked.output.contains("timer(...) requires `import metronome/timers`")

    for (call, diagnostic) in [
      ("every(seconds=1, onError=handler)",
        "`onError` is only supported for async interval jobs"),
      ("cron(onError=handler)",
        "`onError` is only supported for async cron jobs"),
      ("at(time=now(), onError=handler)",
        "`onError` is only supported for async one-shot jobs"),
      ("timer(onCalendar=\"daily UTC\", onError=handler)",
        "`onError` is only supported for async timer jobs"),
      ("every(unexpected=1)", "unexpected parameter for `every`: unexpected"),
      ("cron(unexpected=1)", "unexpected parameter for `cron`: unexpected"),
      ("at(time=now(), unexpected=1)", "unexpected parameter for `at`: unexpected"),
      ("timer(onCalendar=\"daily UTC\", unexpected=1)",
        "unexpected parameter for `timer`: unexpected"),
      ("at(async=true)", "missing required parameter for `at`: time"),
      ("timer(async=true)", "missing required parameter for `timer`: onCalendar")
    ]:
      let source = "import std/[asyncdispatch, times]\n" &
        "import metronome\nimport metronome/timers\n" &
        "proc handler(fut: Future[void]) {.gcsafe.} = discard\n" &
        entry & "\n  " & call & ":\n    discard\n"
      let checked = checkConsumer(source)
      checkpoint source & checked.output
      check checked.exitCode != 0
      check checked.output.contains(diagnostic)

test "Scheduler macro supports one-shot jobs":
  macroOnceCalls = 0
  let scheduled = now() + initDuration(milliseconds=30)

  scheduler testOnce:
    at(time=scheduled, id="once", async=true):
      await macroOnceJob()

  proc main(): Future[void] {.async.} =
    await testOnce.start()
    await sleepAsync(90)

  waitFor main()

  check macroOnceCalls == 1
  check testOnce.jobState("once").get == bsStopped

test "Scheduler startup returns with pending jobs and stopAll allows active completion":
  privateAccess(Scheduler)
  let scheduler = initScheduler(newSettings())
  let active = newFuture[void]("scheduler active job")
  var launches = 0
  let job: BeaterAsyncProc = proc(): Future[void] =
    launches.inc
    active
  scheduler.register(initBeater(
    dateTime(2000, mJan, 1, 0, 0, 0, 0, utc()), job, id="active"
  ))
  scheduler.register(initBeater(
    dateTime(2100, mJan, 1, 0, 0, 0, 0, utc()), job, id="pending"
  ))
  let startup = scheduler.start()
  check startup.finished
  waitFor startup
  check scheduler.futures.len == 2
  check not scheduler.futures[1].finished
  check scheduler.nextRun("pending").isSome
  check scheduler.runningCount("active") == 1
  check not active.finished
  scheduler.stopAll()
  for firing in scheduler.futures:
    waitFor firing
  check scheduler.jobState("pending").get() == bsStopped
  check scheduler.nextRun("pending").isNone
  check scheduler.runningCount("active") == 1
  check not active.finished
  active.complete()
  waitFor sleepAsync(0)
  check scheduler.runningCount("active") == 0
  check launches == 1

test "Repeated scheduler startup and waitFor keep existing nonblocking semantics":
  privateAccess(Scheduler)
  proc main() =
    var queries = 0
    let empty: NextRunProc = proc(current: DateTime): Option[DateTime] {.
        gcsafe, raises: []
      .} =
      queries.inc
      none(DateTime)
    let scheduler = initScheduler(newSettings())
    scheduler.register(initBeater(empty, noop, id="exhausted"))
    let pending = newFuture[void]("waitFor does not drain this job")
    scheduler.register(initBeater(
      dateTime(2000, mJan, 1, 0, 0, 0, 0, utc()),
      proc(): Future[void] = pending, id="pending-job"
    ))
    waitFor scheduler.start()
    waitFor scheduler.start()
    scheduler.waitFor()
    check queries == 3
    check scheduler.futures.len == 6
    for firing in scheduler.futures:
      check firing.finished
    check scheduler.jobState("exhausted").get() == bsRunning
    check scheduler.lastRun("exhausted").isNone
    check not pending.finished
    check scheduler.runningCount("pending-job") == 1
    pending.complete()
    waitFor sleepAsync(0)
    check scheduler.runningCount("pending-job") == 0

  main()

test "Scheduler fallback handler records async failures after startup returns":
  macroErrorHandlerCalls = 0
  let scheduler = initScheduler(newSettings(errorHandler=macroErrorHandler))
  scheduler.register(initBeater(
    dateTime(2000, mJan, 1, 0, 0, 0, 0, utc()), failingJob, id="failure"
  ))
  waitFor scheduler.start()
  waitFor sleepAsync(0)
  check macroErrorHandlerCalls == 1
  check scheduler.failures("failure") == 1
  check scheduler.lastError("failure").msg.contains("boom")
  check scheduler.lastErrorAt("failure").isSome
  check scheduler.runningCount("failure") == 0
