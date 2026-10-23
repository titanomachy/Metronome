import unittest
import times, options, asyncdispatch
import std/[atomics, importutils, os, random]
import metronome

proc dummyAsync(): Future[void] {.async.} = discard

proc failingAsync(): Future[void] {.async.} =
  raise newException(ValueError, "boom")

proc synchronouslyFailing(): Future[void] =
  raise newException(ValueError, "synchronous boom")

proc nilFuture(): Future[void] =
  nil

proc shortThread() {.thread, gcsafe.} =
  discard

var threadEntered, releaseThread: Atomic[bool]

proc heldThread() {.thread, gcsafe.} =
  threadEntered.store(true)
  # Bound the fixture even if a failed assertion prevents normal release.
  for attempt in 0..<2000:
    if releaseThread.load():
      break
    sleep(1)

proc fixedTimezone(name: string, offset: int): Timezone =
  # std/times offsets are seconds west of UTC. No host zoneinfo is consulted.
  proc fromTime(time: Time): ZonedTime =
    ZonedTime(time: time, utcOffset: offset, isDst: false)
  proc fromAdjTime(time: Time): ZonedTime =
    ZonedTime(time: time + initDuration(seconds=offset),
      utcOffset: offset, isDst: false)
  newTimezone(name, fromTime, fromAdjTime)

var beaterHandlerCalls = 0
var fallbackHandlerCalls = 0
var onceLaunches = 0

proc beaterHandler(fut: Future[void]) {.gcsafe.} =
  discard fut.readError()
  beaterHandlerCalls.inc

proc fallbackHandler(fut: Future[void]) {.gcsafe.} =
  discard fut.readError()
  fallbackHandlerCalls.inc

proc countedOnce(): Future[void] {.async.} =
  onceLaunches.inc

test "Beater calculation reads mutable schedule fields without changing execution state":
  let current = dateTime(2026, mJan, 1, 11, 30, 0, 123_456_789, utc())
  let intervalBeater = initBeater(
    initTimeInterval(minutes=10), dummyAsync, startTime=some(current),
    jitter=initTimeInterval(minutes=1)
  )
  intervalBeater.interval = initTimeInterval(minutes=20)
  intervalBeater.jitter = initTimeInterval()
  check intervalBeater.fireTime(some(current), current).get() ==
    current + initDuration(minutes=20)

  let cronCurrent = dateTime(2026, mJan, 1, 11, 30, 0, 0, utc())
  let cronBeater = initBeater(newCron(hour="12", minute="0"), dummyAsync)
  cronBeater.cron = newCron(hour="14", minute="0")
  check cronBeater.fireTime(none(DateTime), cronCurrent).get() ==
    dateTime(2026, mJan, 1, 14, 0, 0, 0, utc())
  proc fromTime(time: Time): ZonedTime =
    ZonedTime(time: time, utcOffset: -7200, isDst: false)
  proc fromAdjTime(time: Time): ZonedTime =
    ZonedTime(time: time - initDuration(hours=2), utcOffset: -7200, isDst: false)
  cronBeater.timezone = some(newTimezone("Test/UTC+02", fromTime, fromAdjTime))
  let zonedNext = cronBeater.fireTime(none(DateTime), cronCurrent).get()
  check zonedNext == dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  check zonedNext.timezone == utc()

  let empty: NextRunProc = proc(current: DateTime): Option[DateTime] {.
      gcsafe, raises: []
    .} = none(DateTime)
  let customBeater = initBeater(empty, dummyAsync, startTime=some(current))
  check customBeater.fireTime(none(DateTime), current).isNone
  customBeater.nextRunProc = proc(current: DateTime): Option[DateTime] {.
      gcsafe, raises: []
    .} = some(current + initDuration(nanoseconds=1))
  check customBeater.fireTime(none(DateTime), current).get() ==
    current + initDuration(nanoseconds=1)

  for beater in [intervalBeater, cronBeater, customBeater]:
    check beater.state == bsRunning
    check beater.lastRun.isNone
    check beater.nextRun.isNone
    check beater.runningCount == 0
    check beater.failures == 0

test "IntervalBeater.$":
  let beater = initBeater(initTimeInterval(seconds=1), dummyAsync)
  check $beater == "Beater(bkInterval,1 second)"

# The arithmetic matrix lives in test_schedule_calculation.nim. Keep public
# adapter checks here, including prev forwarding and inclusive bounds.
test "IntervalBeater.fireTime delegates explicit inputs and bounds":
  let start = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  let current = start + initDuration(minutes=30)
  let target = dateTime(2026, mJan, 1, 12, 40, 0, 0, utc())
  let beater = initBeater(
    initTimeInterval(minutes=10), dummyAsync,
    startTime=some(start), endTime=some(target)
  )
  check beater.fireTime(none(DateTime), start - initDuration(seconds=1)) == some(start)
  check beater.fireTime(none(DateTime), start) == some(start)
  check beater.fireTime(none(DateTime), current) == some(target)
  check beater.fireTime(some(start), current) ==
    some(dateTime(2026, mJan, 1, 12, 10, 0, 0, utc()))
  check beater.fireTime(some(target), current).isNone

  let bounded = initBeater(
    initTimeInterval(minutes=10), dummyAsync, startTime=some(start),
    endTime=some(target - initDuration(nanoseconds=1))
  )
  check bounded.fireTime(none(DateTime), current).isNone

test "IntervalBeater.fireTime jitter keeps nominal cadence with controlled samples":
  privateAccess(Beater)
  let start = dateTime(2026, mJan, 1, 12, 0, 0, 123_456_789, utc())
  let beater = initBeater(
    initTimeInterval(seconds=10), dummyAsync, startTime=some(start),
    jitter=initTimeInterval(milliseconds=1)
  )
  beater.jitterRand = initRand(1)
  var expectedRand = initRand(1)
  var previous = start
  for occurrence in 1..3:
    let nominal = dateTime(2026, mJan, 1, 12, 0, occurrence * 10,
      123_456_789, utc())
    let offsetMs = expectedRand.rand(1)
    check beater.fireTime(some(previous), start) ==
      some(nominal + initDuration(milliseconds=offsetMs))
    check beater.jitterRand == expectedRand
    previous = nominal

test "IntervalBeater.fireTime | jitter includes both endpoints and samples once per preview":
  privateAccess(Beater)
  let zone = fixedTimezone("Test/Jitter", -7200)
  let current = dateTime(2026, mJan, 1, 12, 0, 0, 123_456_789, zone)
  let nominal = current + initDuration(seconds=10)
  var seen: array[2, bool]
  for seed in 1..8:
    let beater = initBeater(
      initTimeInterval(seconds=10), dummyAsync, startTime=some(nominal),
      jitter=initTimeInterval(milliseconds=1)
    )
    beater.jitterRand = initRand(seed)
    var expectedRand = initRand(seed)
    for preview in 1..2:
      let offsetMs = expectedRand.rand(1)
      let actual = beater.fireTime(none(DateTime), current).get()
      check actual == nominal + initDuration(milliseconds=offsetMs)
      check actual.nanosecond mod 1_000_000 == nominal.nanosecond mod 1_000_000
      check actual.timezone == zone
      check beater.jitterRand == expectedRand
      check beater.nextRun.isNone
      check beater.lastRun.isNone
      seen[offsetMs] = true
  check seen == [true, true]

test "IntervalBeater.fireTime | non-positive and sub-millisecond jitter do not sample":
  privateAccess(Beater)
  let current = dateTime(2026, mJan, 1, 12, 0, 0, 123_456_789, utc())
  for jitter in [initTimeInterval(), initTimeInterval(milliseconds= -1),
      initTimeInterval(nanoseconds=999_999)]:
    let beater = initBeater(
      initTimeInterval(seconds=10), dummyAsync, startTime=some(current), jitter=jitter
    )
    let initialRand = initRand(42)
    beater.jitterRand = initialRand
    check beater.fireTime(none(DateTime), current).get() == current
    check beater.jitterRand == initialRand

test "IntervalBeater.fireTime | calendar jitter is measured at each nominal occurrence":
  privateAccess(Beater)
  let start = dateTime(2023, mDec, 1, 0, 0, 0, 123_456_789, utc())
  let current = dateTime(2024, mApr, 1, 0, 0, 0, 0, utc())
  let beater = initBeater(
    initTimeInterval(months=1), dummyAsync, startTime=some(start),
    jitter=initTimeInterval(months=1)
  )
  beater.jitterRand = initRand(42)
  var expectedRand = initRand(42)
  var previous = dateTime(2024, mJan, 1, 0, 0, 0, 123_456_789, utc())
  for (month, days) in [(mFeb, 29), (mMar, 31)]:
    let nominal = dateTime(2024, month, 1, 0, 0, 0, 123_456_789, utc())
    # These windows exceed a 32-bit int; retain the platform's existing cap.
    let maxOffsetMs = int(min(int64(days) * 86_400_000, int64(high(int))))
    let offsetMs = expectedRand.rand(maxOffsetMs)
    let actual = beater.fireTime(some(previous), current).get()
    check actual == nominal + initDuration(milliseconds=offsetMs)
    check actual.nanosecond mod 1_000_000 == 456_789
    check beater.jitterRand == expectedRand
    previous = nominal

test "Beater deadline planning | inspection and execution share inclusive jitter bounds":
  privateAccess(Beater)
  let nominal = dateTime(2100, mJan, 1, 0, 0, 0, 123_456_789, utc())
  let current = nominal - initDuration(days=1)
  let initialRand = initRand(1)
  var sampledRand = initialRand
  # A one-millisecond sample exercises rejection after jitter and its exact edge.
  require sampledRand.rand(1) == 1
  for endTime in [nominal - initDuration(nanoseconds=1), nominal,
      nominal + initDuration(milliseconds=1)]:
    let preview = initBeater(
      initTimeInterval(seconds=10), dummyAsync, startTime=some(nominal),
      endTime=some(endTime), jitter=initTimeInterval(milliseconds=1)
    )
    let live = initBeater(
      initTimeInterval(seconds=10), dummyAsync, startTime=some(nominal),
      endTime=some(endTime), jitter=initTimeInterval(milliseconds=1)
    )
    preview.jitterRand = initialRand
    live.jitterRand = initialRand
    let inspected = preview.fireTime(none(DateTime), current)
    let firing = live.fire()
    if endTime > nominal:
      check inspected == some(endTime)
      check not firing.finished
    else:
      check inspected.isNone
      check firing.finished
    check live.nextRun == inspected
    check live.lastRun.isNone
    let expectedRand = if endTime < nominal: initialRand else: sampledRand
    check preview.jitterRand == expectedRand
    check live.jitterRand == expectedRand
    live.stop()
    waitFor firing

test "Beater deadline planning | launches and throttled occurrences retain nominal cadence":
  privateAccess(Beater)
  let nominal = dateTime(2000, mJan, 1, 0, 0, 0, 0, utc())
  for throttle in [false, true]:
    var launches = 0
    let job: BeaterAsyncProc = proc(): Future[void] =
      launches.inc
      result = newFuture[void]("jitter cadence job")
      result.complete()
    let beater = initBeater(
      initTimeInterval(milliseconds=5), job, startTime=some(nominal),
      endTime=some(nominal + initDuration(milliseconds=10)),
      jitter=initTimeInterval(milliseconds=1)
    )
    # Supply an overdue prior nominal time through the existing resume input,
    # so all three occurrences are evaluated without clock sleeps.
    beater.resumeTime = some(nominal - initDuration(milliseconds=5))
    beater.jitterRand = initRand(1)
    var expectedRand = initRand(1)
    require expectedRand.rand(1) == 1
    discard expectedRand.rand(1)
    let lastOffset = expectedRand.rand(1)
    let blocker = newFuture[void]("jitter throttle blocker")
    if throttle:
      beater.throttler.submit(blocker)

    waitFor beater.fire()
    # Completed job futures queue their tracking callbacks for the event loop.
    waitFor sleepAsync(0)

    check beater.jitterRand == expectedRand
    check launches == (if throttle: 0 elif lastOffset == 0: 3 else: 2)
    check beater.nextRun.isNone
    check beater.runningCount == 0
    check beater.lastRun.isSome == not throttle
    blocker.complete()

test "Published jittered deadlines govern waiting and retain nominal interval cadence":
  privateAccess(Beater)
  proc main() =
    let nominal = now() + initDuration(milliseconds=20)
    let interval = initTimeInterval(hours=1)
    var expectedRand = initRand(1)
    let firstOffset = expectedRand.rand(100)
    require firstOffset > 0
    let firstDeadline = nominal + initDuration(milliseconds=firstOffset)
    let secondDeadline = nominal + interval +
      initDuration(milliseconds=expectedRand.rand(100))
    let launched = newFuture[void]("jittered launch signal")
    var launchTime, pendingAtLaunch: Option[DateTime]
    var beater: Beater
    let job: BeaterAsyncProc = proc(): Future[void] {.async.} =
      launchTime = some(now())
      pendingAtLaunch = beater.nextRun
      launched.complete()
    beater = initBeater(interval, job, startTime=some(nominal),
      jitter=initTimeInterval(milliseconds=100))
    # Preserve the intended first occurrence even if setup is delayed by load.
    beater.resumeTime = some(nominal - interval)
    beater.jitterRand = initRand(1)
    let firing = beater.fire()
    defer:
      beater.stop()
      waitFor firing
      waitFor sleepAsync(0)

    # fire() may already have launched if the process was descheduled.
    if not launched.finished:
      check beater.nextRun == some(firstDeadline)
    require waitFor withTimeout(launched, 1000)
    check pendingAtLaunch == some(firstDeadline)
    check launchTime.get() >= firstDeadline
    check beater.lastRun.get() >= launchTime.get()
    check beater.nextRun == some(secondDeadline)
    check beater.jitterRand == expectedRand

  main()

test "Beater.fireTime | non-interval schedules do not consume jitter randomness":
  privateAccess(Beater)
  let current = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  let custom: NextRunProc = proc(current: DateTime): Option[DateTime] {.
      gcsafe, raises: []
    .} = some(current + initDuration(seconds=1))
  let beaters = [
    initBeater(newCron(hour="13", minute="0"), dummyAsync),
    initBeater(custom, dummyAsync, startTime=some(current)),
    initBeater(current, dummyAsync)
  ]
  for beater in beaters:
    let initialRand = initRand(42)
    beater.jitterRand = initialRand
    check beater.fireTime(none(DateTime), current).isSome
    check beater.jitterRand == initialRand

test "CronBeater.fireTime | timezone":
  let current = dateTime(2026, mJan, 1, 11, 30, 0, 0, utc())
  let beater = initBeater(
    newCron(hour="12", minute="0"),
    dummyAsync,
    timezone=some(utc())
  )
  let actual = beater.fireTime(none(DateTime), current).get()
  let expect = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  check actual == expect

test "CronBeater.fireTime | current time determines the query despite startTime and prev":
  let current = dateTime(2026, mJan, 1, 11, 30, 0, 0, utc())
  let futureStart = current + initDuration(days=1)
  let beater = initBeater(
    newCron(hour="12", minute="0"), dummyAsync,
    startTime=some(futureStart)
  )
  let expected = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())

  check beater.fireTime(none(DateTime), current).get() == expected
  check beater.fireTime(some(futureStart), current).get() == expected

test "CronBeater.fireTime | configured zone returns in caller zone with inclusive bounds":
  let callerZone = fixedTimezone("Test/UTC-05", 5 * 3600)
  let scheduleZone = fixedTimezone("Test/UTC+02", -2 * 3600)
  let current = dateTime(2026, mJan, 1, 6, 30, 0, 0, callerZone)
  let deadline = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  let cron = newCron(hour="14", minute="0")
  let beater = initBeater(
    cron, dummyAsync, timezone=some(scheduleZone), endTime=some(deadline)
  )
  let actual = beater.fireTime(none(DateTime), current).get()

  check actual == deadline
  check actual.hour == 7
  check actual.timezone == callerZone
  # The underlying cron evaluator includes an already matching minute.
  check beater.fireTime(some(actual), actual).get() == actual

  let tooLate = initBeater(
    cron, dummyAsync, timezone=some(scheduleZone),
    endTime=some(deadline - initDuration(nanoseconds=1))
  )
  check tooLate.fireTime(none(DateTime), current).isNone

  let callerCron = initBeater(newCron(hour="12", minute="0"), dummyAsync)
  let callerNext = callerCron.fireTime(none(DateTime), current).get()
  check callerNext == dateTime(2026, mJan, 1, 17, 0, 0, 0, utc())
  check callerNext.timezone == callerZone

test "OnceBeater.fireTime":
  let scheduled = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  let beater = initBeater(scheduled, dummyAsync)

  check beater.fireTime(none(DateTime), scheduled - initTimeInterval(hours=1)).get() == scheduled
  check beater.fireTime(some(scheduled), scheduled).isNone

test "Custom Beater delegates to a strictly-future callback":
  let callback: NextRunProc = proc(current: DateTime): Option[DateTime] {.
      gcsafe, raises: []
    .} =
    some(current + initDuration(microseconds=500))
  let current = dateTime(2026, mJan, 1, 0, 0, 0, 0, utc())
  let beater = initBeater(callback, dummyAsync, startTime=some(current))
  let next = beater.fireTime(none(DateTime), current).get()

  check beater.kind == bkCustom
  check next == current + initDuration(microseconds=500)
  check $beater == "Beater(bkCustom)"

test "Custom Beater rejects a nil callback":
  let callback: NextRunProc = nil
  expect ValueError:
    discard initBeater(callback, dummyAsync)
  expect ValueError:
    discard initBeater(callback, shortThread)

test "Custom Beater queries just before a future start and otherwise from current time":
  let callback: NextRunProc = proc(current: DateTime): Option[DateTime] {.
      gcsafe, raises: []
    .} =
    some(current + initDuration(nanoseconds=1))
  let current = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  let start = current + initDuration(seconds=1, nanoseconds=123_456_789)
  let beater = initBeater(callback, dummyAsync, startTime=some(start))

  check beater.fireTime(none(DateTime), current).get() == start
  check beater.fireTime(some(start), current).get() == start
  check beater.fireTime(none(DateTime), start).get() ==
    start + initDuration(nanoseconds=1)
  check beater.fireTime(some(current), start).get() ==
    start + initDuration(nanoseconds=1)

test "Custom Beater keeps precise targets and includes the upper bound":
  let callback: NextRunProc = proc(current: DateTime): Option[DateTime] {.
      gcsafe, raises: []
    .} =
    some(current + initDuration(microseconds=500))
  let current = dateTime(2026, mJan, 1, 12, 0, 0, 123_456_789, utc())
  let deadline = current + initDuration(microseconds=500)
  let beater = initBeater(
    callback, dummyAsync, startTime=some(current), endTime=some(deadline)
  )

  check beater.fireTime(none(DateTime), current).get() == deadline
  check beater.fireTime(none(DateTime), current + initDuration(nanoseconds=1)).isNone

test "Custom Beater invokes a stateful callback once and preserves its result zone":
  proc main() =
    let current = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
    let targetZone = fixedTimezone("Test/UTC+0545", -(5 * 3600 + 45 * 60))
    let target = (current + initDuration(microseconds=500, nanoseconds=123)).inZone(targetZone)
    var queries: seq[DateTime]
    let callback: NextRunProc = proc(query: DateTime): Option[DateTime] {.
        gcsafe, raises: []
      .} =
      queries.add(query)
      if queries.len == 1: some(target) else: none(DateTime)
    let beater = initBeater(
      callback, dummyAsync, startTime=some(current), endTime=some(target.utc())
    )
    let actual = beater.fireTime(none(DateTime), current).get()
    check actual == target
    check actual.nanosecond == 500_123
    check actual.timezone == targetZone
    check queries == @[current]
    # Identical inputs need not repeat the result of a user callback.
    check beater.fireTime(none(DateTime), current).isNone
    check queries == @[current, current]
    check beater.nextRun.isNone
    check beater.lastRun.isNone

  main()

test "Built-in Beater calculations repeat for fixed inputs without updating execution":
  let current = dateTime(2026, mJan, 1, 12, 35, 0, 0, utc())
  let anchor = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  let deadline = current - initDuration(nanoseconds=123)
  let zone = fixedTimezone("Test/UTC+02", -2 * 3600)
  let beaters = [
    initBeater(initTimeInterval(minutes=10), dummyAsync, startTime=some(anchor)),
    initBeater(newCron(hour="14", minute="0"), dummyAsync, timezone=some(zone)),
    initBeater(deadline.inZone(zone), dummyAsync)
  ]

  for beater in beaters:
    for prev in [none(DateTime), some(anchor)]:
      let first = beater.fireTime(prev, current)
      check beater.fireTime(prev, current) == first
    check beater.state == bsRunning
    check beater.lastRun.isNone
    check beater.nextRun.isNone
    check beater.runningCount == 0
    check beater.failures == 0

  let once = beaters[2].fireTime(none(DateTime), current).get()
  check once == deadline
  check once.nanosecond == 999_999_877
  check once.timezone == zone

test "Beater calculation exhaustion clears nextRun without stopping or launching":
  let empty: NextRunProc = proc(current: DateTime): Option[DateTime] {.
      gcsafe, raises: []
    .} =
    none(DateTime)
  let past = dateTime(2000, mJan, 1, 0, 0, 0, 0, utc())
  let beaters = [
    initBeater(empty, dummyAsync, startTime=some(past)),
    initBeater(
      initTimeInterval(seconds=1), dummyAsync,
      startTime=some(past), endTime=some(past)
    ),
    initBeater(newCron(), dummyAsync, endTime=some(past))
  ]

  for beater in beaters:
    check beater.fireTime(none(DateTime), past + initDuration(days=1)).isNone
    waitFor beater.fire()
    check beater.nextRun.isNone
    check beater.lastRun.isNone
    check beater.runningCount == 0
    check beater.failures == 0
    check beater.state == bsRunning

test "Custom Beater does not intentionally launch before a sub-millisecond deadline":
  proc main() =
    var target, launched: Option[DateTime]
    var queries, launches: int
    let callback: NextRunProc = proc(current: DateTime): Option[DateTime] {.
        gcsafe, raises: []
      .} =
      queries.inc
      if queries == 1:
        # Set the target at calculation time, so constructor/setup latency
        # cannot exhaust the callback before its first occurrence is planned.
        target = some(current + initDuration(microseconds=500))
        target
      else:
        none(DateTime)
    let job: BeaterAsyncProc = proc(): Future[void] {.async.} =
      launches.inc
      launched = some(now())
    let beater = initBeater(callback, job)
    let firing = beater.fire()
    defer:
      beater.stop()
      waitFor firing
      waitFor sleepAsync(0)

    require waitFor withTimeout(firing, 1000)
    check queries == 2
    check launches == 1
    require launched.isSome
    check launched.get() >= target.get()
    check beater.nextRun.isNone

  main()

test "Throttler rejects invalid limits":
  expect ValueError:
    discard initThrottler(0)

test "Throttler releases capacity after failed futures finish":
  let throttler = initThrottler()
  let fut = newFuture[void]("failed throttle test")

  throttler.submit(fut)
  check throttler.throttled

  fut.fail(newException(ValueError, "boom"))
  check not throttler.throttled

test "Thread-backed jobs promptly report completion":
  proc main(): Future[int] {.async.} =
    let beater = initBeater(now(), shortThread, id="short-thread")
    await beater.fire()
    await sleepAsync(100)
    result = beater.runningCount

  check waitFor(main()) == 0

test "Beater.fire records failed jobs":
  let current = now().utc()
  let beater = initBeater(
    initTimeInterval(milliseconds=1),
    failingAsync,
    startTime=some(current),
    endTime=some(current + initTimeInterval(milliseconds=5)),
    id="failing"
  )

  waitFor beater.fire()

  check beater.lastRun.isSome
  check beater.nextRun.isNone
  check beater.lastError != nil
  check beater.lastError.msg == "boom"
  check beater.lastErrorAt.isSome
  check beater.failures > 0
  check beater.runningCount == 0

test "Beater.fire survives failures raised while invoking jobs":
  let current = now().utc()
  let beater = initBeater(
    initTimeInterval(milliseconds=1),
    synchronouslyFailing,
    startTime=some(current),
    endTime=some(current + initTimeInterval(milliseconds=5)),
    id="synchronously-failing",
    errorHandler=beaterHandler
  )

  beaterHandlerCalls = 0
  waitFor beater.fire()

  check beater.failures > 1
  check beater.failures == beaterHandlerCalls
  check beater.lastError.msg == "synchronous boom"
  check beater.runningCount == 0

test "Beater.fire records nil job futures without stopping its loop":
  let current = now().utc()
  let beater = initBeater(
    initTimeInterval(milliseconds=1),
    nilFuture,
    startTime=some(current),
    endTime=some(current + initTimeInterval(milliseconds=5)),
    id="nil-future",
    errorHandler=beaterHandler
  )

  beaterHandlerCalls = 0
  waitFor beater.fire()

  check beater.failures > 1
  check beater.failures == beaterHandlerCalls
  check beater.lastError.msg == "scheduled job returned a nil future"
  check beater.runningCount == 0

test "Beater job error handler takes precedence":
  beaterHandlerCalls = 0
  fallbackHandlerCalls = 0
  let current = now().utc()
  let beater = initBeater(
    initTimeInterval(milliseconds=1),
    failingAsync,
    startTime=some(current),
    endTime=some(current + initTimeInterval(milliseconds=5)),
    id="failing-with-handler",
    errorHandler=beaterHandler
  )

  waitFor beater.fire(fallbackHandler)

  check beaterHandlerCalls > 0
  check fallbackHandlerCalls == 0
  check beater.lastError.msg == "boom"
  check beater.failures == beaterHandlerCalls

test "Beater lifecycle controls update state":
  let beater = initBeater(initTimeInterval(seconds=1), dummyAsync, id="tick")

  check beater.id == "tick"
  check beater.state == bsRunning

  beater.pause()
  check beater.state == bsPaused

  beater.resume()
  check beater.state == bsRunning

  beater.stop()
  check beater.state == bsStopped
  check beater.nextRun.isNone

test "Beater.pause clears pending next run":
  proc main(): Future[bool] {.async.} =
    let current = now()
    let beater = initBeater(
      initTimeInterval(seconds=1),
      dummyAsync,
      startTime=some(current + initTimeInterval(seconds=1)),
      endTime=some(current + initTimeInterval(seconds=3)),
      id="pausable"
    )
    let fut = beater.fire()
    defer: beater.stop()
    check beater.nextRun.isSome

    beater.pause()
    result = beater.state == bsPaused and beater.nextRun.isNone

    beater.stop()
    await fut

  check waitFor(main())

test "Beater.resume skips intervals missed while paused":
  privateAccess(Beater)
  proc main(): Future[bool] {.async.} =
    var launches: seq[DateTime]
    let resumedLaunch = newFuture[void]("first launch after resume")
    let job: BeaterAsyncProc = proc(): Future[void] {.async.} =
      launches.add(now())
      if launches.len == 2:
        resumedLaunch.complete()
    let current = now()
    let beater = initBeater(
      initTimeInterval(milliseconds=20), job,
      startTime=some(current), id="skip-missed"
    )
    beater.resumeTime = some(current - initDuration(milliseconds=20))
    let fut = beater.fire()
    defer: beater.stop()
    check launches.len == 1

    beater.pause()
    await sleepAsync(90)
    check launches.len == 1

    let beforeResume = now()
    beater.resume()
    result = await withTimeout(resumedLaunch, 1000)

    beater.stop()
    await fut
    for actual in launches[1..^1]:
      check actual >= beforeResume + initDuration(milliseconds=20)

  check waitFor(main())

test "Beater.resume before pending deadline recomputes next run":
  proc main(): Future[bool] {.async.} =
    let current = now()
    let original = current + initDuration(minutes=10)
    let beater = initBeater(
      initTimeInterval(hours=1), dummyAsync, startTime=some(original),
      id="resume-recomputes"
    )
    let fut = beater.fire()
    defer: beater.stop()
    check beater.nextRun.isSome

    beater.pause()
    await sleepAsync(20)
    let beforeResume = now()
    beater.resume()
    let afterResume = now()
    # Poll only for the recomputed pending deadline, never for a launch.
    for attempt in 0..<200:
      if beater.nextRun.isSome:
        break
      await sleepAsync(5)
    result = beater.lastRun.isNone and beater.nextRun.isSome
    if beater.nextRun.isSome:
      check beater.nextRun.get() != original
      check beater.nextRun.get() >= beforeResume + initDuration(hours=1)
      check beater.nextRun.get() <= afterResume + initDuration(hours=1)

    beater.stop()
    await fut

  check waitFor(main())

test "Beater one-shot resumes pending run":
  onceLaunches = 0

  proc main(): Future[bool] {.async.} =
    let current = now()
    let beater = initBeater(
      current + initTimeInterval(milliseconds=80),
      countedOnce,
      id="one-shot"
    )
    let fut = beater.fire()
    defer: beater.stop()
    check beater.nextRun.isSome

    beater.pause()
    beater.resume()
    result = await withTimeout(fut, 1000)
    check onceLaunches == 1
    check beater.state == bsStopped
    check beater.lastRun.get() >= current + initDuration(milliseconds=80)

    beater.stop()
    await fut

  check waitFor(main())

test "Beater constructor families preserve defaults and validation":
  privateAccess(Beater)
  privateAccess(Throttler)
  let empty: NextRunProc = proc(current: DateTime): Option[DateTime] {.
      gcsafe, raises: []
    .} = none(DateTime)
  let deadline = dateTime(2000, mJan, 1, 0, 0, 0, 0, utc())
  template verify(schedule: untyped, expectedKind: BeaterKind) =
    block:
      let before = now()
      let asyncBeater = initBeater(schedule, dummyAsync)
      let threadBeater = initBeater(schedule, shortThread)
      let after = now()
      for beater in [asyncBeater, threadBeater]:
        check beater.kind == expectedKind
        check beater.id == ""
        check beater.state == bsRunning
        check beater.throttler.num == 1
        check beater.runningCount == 0
        check beater.lastRun.isNone
        check beater.nextRun.isNone
        check beater.endTime.isNone
        check beater.errorHandler.isNil
        check beater.lastError.isNil
        check beater.lastErrorAt.isNone
        check beater.failures == 0
        if expectedKind == bkOnce:
          check beater.startTime == deadline
        else:
          check beater.startTime >= before
          check beater.startTime <= after
      expect ValueError:
        discard initBeater(schedule, dummyAsync, throttleNum=0)
      expect ValueError:
        discard initBeater(schedule, shortThread, throttleNum=0)
      expect ValueError:
        discard initBeater(schedule, shortThread, errorHandler=beaterHandler)
  verify(initTimeInterval(seconds=1), bkInterval)
  verify(newCron(), bkCron)
  verify(empty, bkCustom)
  verify(deadline, bkOnce)
  check initBeater(initTimeInterval(seconds=1), dummyAsync).jitter == initTimeInterval()
  check initBeater(newCron(), dummyAsync).timezone.isNone

test "Immediate pause/resume invalidates an interval wait and uses resume time":
  let current = now()
  let deadline = current + initDuration(hours=1)
  let beater = initBeater(
    initTimeInterval(days=1), dummyAsync,
    startTime=some(deadline), endTime=some(deadline)
  )
  let firing = beater.fire()
  defer:
    beater.stop()
    waitFor firing

  check beater.nextRun == some(deadline)
  # No event-loop turn between pause and resume: state alone cannot detect this.
  for cycle in 0..<2:
    beater.pause()
    check beater.nextRun.isNone
    beater.resume()

  # Resume + one day exceeds endTime. Reusing the invalidated wait would hang.
  check waitFor withTimeout(firing, 1000)
  check beater.nextRun.isNone
  check beater.lastRun.isNone
  check beater.runningCount == 0
  check beater.state == bsRunning

test "Paused one-shots retain overdue deadlines and stop after one launch":
  proc main(): Future[void] {.async.} =
    for initiallyOverdue in [true, false]:
      let deadline = if initiallyOverdue:
        dateTime(2000, mJan, 1, 0, 0, 0, 0, utc())
      else:
        now() + initDuration(milliseconds=20)
      var launches = 0
      let active = newFuture[void]("paused one-shot job")
      let job: BeaterAsyncProc = proc(): Future[void] =
        launches.inc
        active
      let beater = initBeater(deadline, job)
      # Pause before starting so system load cannot race the future deadline.
      beater.pause()
      let firing = beater.fire()
      check beater.nextRun.isNone
      if not initiallyOverdue:
        await sleepAsync(30)
        check now() >= deadline
      check launches == 0
      beater.resume()
      let finished = await withTimeout(firing, 1000)
      check beater.state == bsStopped
      beater.stop()
      await firing
      check finished
      check launches == 1
      check beater.state == bsStopped
      check beater.nextRun.isNone
      check beater.lastRun.get() >= deadline
      check beater.runningCount == 1
      check not active.finished
      # Neither restarting the fire loop nor resuming revives a stopped beater.
      beater.resume()
      await beater.fire()
      check launches == 1
      active.complete()
      await sleepAsync(0)
      check beater.runningCount == 0

  waitFor main()

test "Pause and stop retain an active async job and its actual launch timestamp":
  privateAccess(Beater)
  privateAccess(Throttler)
  proc main(): Future[void] {.async.} =
    let active = newFuture[void]("active job across stop")
    let launched = newFuture[void]("launch signal")
    var launches = 0
    let job: BeaterAsyncProc = proc(): Future[void] =
      launches.inc
      launched.complete()
      active
    let deadline = now()
    let beater = initBeater(
      initTimeInterval(hours=1), job, startTime=some(deadline)
    )
    # An overdue prior occurrence avoids racing initial alignment under load.
    beater.resumeTime = some(deadline - initDuration(hours=1))
    let firing = beater.fire()
    let didLaunch = await withTimeout(launched, 1000)
    check didLaunch
    let actual = beater.lastRun
    check actual.isSome
    if actual.isSome:
      check actual.get() >= deadline
      check actual.get() <= now()
    check beater.nextRun == some(deadline + initDuration(hours=1))
    beater.pause()
    check beater.nextRun.isNone
    check beater.runningCount == 1
    beater.stop()
    await firing
    check not active.finished
    check beater.runningCount == 1
    check beater.lastRun == actual
    active.complete()
    await sleepAsync(0)
    check beater.runningCount == 0
    check not beater.throttler.throttled
    check beater.throttler.beats.len == 0
    beater.resume()
    await beater.fire()
    check beater.state == bsStopped
    check launches == 1

  waitFor main()

test "Active async jobs finish while paused without launching an overdue occurrence":
  privateAccess(Beater)
  proc main() =
    let active = newFuture[void]("active job completing while paused")
    var launches = 0
    let job: BeaterAsyncProc = proc(): Future[void] =
      launches.inc
      active
    let nominal = now()
    let beater = initBeater(initTimeInterval(milliseconds=10), job,
      startTime=some(nominal))
    beater.resumeTime = some(nominal - initDuration(milliseconds=10))
    let firing = beater.fire()
    defer:
      beater.stop()
      waitFor firing
      if not active.finished:
        active.complete()
      waitFor sleepAsync(0)

    check launches == 1
    check beater.runningCount == 1
    let actual = beater.lastRun
    beater.pause()
    check not active.finished
    check beater.nextRun.isNone
    active.complete()
    # Cross several nominal occurrences while allowing completion tracking
    # and the invalidated wait to run. There is no upper latency assertion.
    waitFor sleepAsync(30)
    check now() >= nominal + initDuration(milliseconds=10)
    check beater.state == bsPaused
    check beater.runningCount == 0
    check beater.nextRun.isNone
    check beater.lastRun == actual
    check launches == 1
    check not firing.finished

  main()

test "Throttled occurrences retain capacity limits and create no deferred jobs":
  privateAccess(Beater)
  privateAccess(Throttler)
  let nominal = dateTime(2000, mJan, 1, 0, 0, 0, 0, utc())
  var active: seq[Future[void]]
  let job: BeaterAsyncProc = proc(): Future[void] =
    result = newFuture[void]("concurrent throttled job")
    active.add(result)
  let beater = initBeater(
    initTimeInterval(seconds=1), job, startTime=some(nominal),
    endTime=some(nominal + initDuration(seconds=3)), throttleNum=2
  )
  beater.resumeTime = some(nominal - initDuration(seconds=1))
  let beforeLaunch = now()
  waitFor beater.fire()
  check active.len == 2
  check beater.runningCount == 2
  check beater.throttler.throttled
  check beater.throttler.beats.len == 2
  check beater.lastRun.get() >= beforeLaunch
  check beater.nextRun.isNone
  check beater.state == bsRunning
  for future in active:
    future.complete()
  waitFor sleepAsync(0)
  check beater.runningCount == 0
  check not beater.throttler.throttled
  check beater.throttler.beats.len == 0
  check beater.throttler.num == 2
  check active.len == 2

test "Catchable job error-handler failures do not stop dispatch or use fallback":
  privateAccess(Beater)
  let nominal = dateTime(2000, mJan, 1, 0, 0, 0, 0, utc())
  var handlerCalls = 0
  let handler: JobErrorHandler = proc(fut: Future[void]) {.gcsafe.} =
    discard fut.readError()
    handlerCalls.inc
    raise newException(ValueError, "handler failed")
  let beater = initBeater(
    initTimeInterval(seconds=1), synchronouslyFailing,
    startTime=some(nominal), endTime=some(nominal + initDuration(seconds=2)),
    errorHandler=handler
  )
  beater.resumeTime = some(nominal - initDuration(seconds=1))
  fallbackHandlerCalls = 0
  let beforeLaunch = now()
  waitFor beater.fire(fallbackHandler)
  waitFor sleepAsync(0)
  check handlerCalls == 3
  check fallbackHandlerCalls == 0
  check beater.failures == 3
  check beater.lastError.msg == "synchronous boom"
  check beater.lastErrorAt.get() >= beforeLaunch
  check beater.runningCount == 0
  check beater.nextRun.isNone
  check beater.state == bsRunning

test "Stopping a thread-backed beater allows its worker to finish and be joined":
  privateAccess(Beater)
  proc main(): Future[void] {.async.} =
    threadEntered.store(false)
    releaseThread.store(false)
    let deadline = now()
    let beater = initBeater(
      initTimeInterval(hours=1), heldThread, startTime=some(deadline)
    )
    beater.resumeTime = some(deadline - initDuration(hours=1))
    let firing = beater.fire()
    proc entered(): Future[void] {.async.} =
      while not threadEntered.load() and beater.state == bsRunning:
        await sleepAsync(1)
    let didEnter = await withTimeout(entered(), 1000)
    check didEnter
    beater.stop()
    await firing
    check beater.runningCount == 1
    releaseThread.store(true)
    proc drained(): Future[void] {.async.} =
      while beater.runningCount > 0:
        await sleepAsync(1)
    check await withTimeout(drained(), 1000)
    check beater.runningCount == 0
    check beater.nextRun.isNone
    check beater.failures == 0

  waitFor main()
