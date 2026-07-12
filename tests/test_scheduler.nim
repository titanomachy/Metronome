import unittest

import times, options, asyncdispatch, strutils
import metronome

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
