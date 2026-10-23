import unittest
import times, options, asyncdispatch
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

var beaterHandlerCalls = 0
var fallbackHandlerCalls = 0
var pauseLaunches = 0
var onceLaunches = 0

proc beaterHandler(fut: Future[void]) {.gcsafe.} =
  discard fut.readError()
  beaterHandlerCalls.inc

proc fallbackHandler(fut: Future[void]) {.gcsafe.} =
  discard fut.readError()
  fallbackHandlerCalls.inc

proc countedAsync(): Future[void] {.async.} =
  pauseLaunches.inc

proc countedOnce(): Future[void] {.async.} =
  onceLaunches.inc

test "IntervalBeater.$":
  let beater = initBeater(initTimeInterval(seconds=1), dummyAsync)
  check $beater == "Beater(bkInterval,1 second)"

test "IntervalBeater.fireTime | startTime hasn't come":
  let current = now().utc()
  let beater = initBeater(
    initTimeInterval(seconds=10),
    dummyAsync,
    startTime=some(current + initTimeInterval(seconds=4))
  )
  let expect = current + initTimeInterval(seconds=4)
  let actual = beater.fireTime(none(DateTime), current).get()
  check actual == expect

test "IntervalBeater.fireTime | startTime equals now":
  let current = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  let beater = initBeater(
    initTimeInterval(seconds=10),
    dummyAsync,
    startTime=some(current)
  )
  let actual = beater.fireTime(none(DateTime), current).get()
  check actual == current

test "IntervalBeater.fireTime | startTime has come":
  let current = now().utc()
  let beater = initBeater(
    initTimeInterval(seconds=10),
    dummyAsync,
    startTime=some(current - initTimeInterval(seconds=14))
  )
  let expect = current + initTimeInterval(seconds=6)
  let actual = beater.fireTime(none(DateTime), current).get()
  check actual == expect

test "IntervalBeater.fireTime | startTime has come 2":
  let current = now().utc()
  let beater = initBeater(
    initTimeInterval(seconds=10),
    dummyAsync,
    startTime=some(current - initTimeInterval(seconds=4))
  )
  let expect = current + initTimeInterval(seconds=6)
  let actual = beater.fireTime(none(DateTime), current).get()
  check actual == expect

test "IntervalBeater.fireTime | some prev":
  let current = now().utc()
  let beater = initBeater(initTimeInterval(seconds=10), dummyAsync)
  let prev = some(current - initTimeInterval(seconds=4))
  let actual = beater.fireTime(prev, current).get()
  let expect = current + initTimeInterval(seconds=6)
  check actual == expect

test "IntervalBeater.fireTime | missed intervals roll over to next future boundary":
  let start = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  let current = dateTime(2026, mJan, 1, 12, 35, 0, 0, utc())
  let beater = initBeater(
    initTimeInterval(minutes=10),
    dummyAsync,
    startTime=some(start)
  )
  let actual = beater.fireTime(none(DateTime), current).get()
  let expect = dateTime(2026, mJan, 1, 12, 40, 0, 0, utc())
  check actual == expect

test "IntervalBeater.fireTime | initial alignment differs from prior nominal progression":
  let start = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  let current = start + initDuration(minutes=30)
  let beater = initBeater(
    initTimeInterval(minutes=10), dummyAsync, startTime=some(start)
  )

  check beater.fireTime(none(DateTime), current).get() ==
    start + initDuration(minutes=40)
  check beater.fireTime(some(start), current).get() ==
    start + initDuration(minutes=10)

test "IntervalBeater.fireTime | calendar intervals retain distinct initial and later arithmetic":
  let start = dateTime(2026, mJan, 1, 0, 0, 0, 0, utc())
  let current = dateTime(2026, mFeb, 15, 0, 0, 0, 0, utc())
  let previous = dateTime(2026, mFeb, 1, 0, 0, 0, 0, utc())
  let beater = initBeater(
    initTimeInterval(months=1), dummyAsync, startTime=some(start)
  )

  # Initial alignment uses the 31-day length measured at January 1.
  check beater.fireTime(none(DateTime), current).get() ==
    dateTime(2026, mMar, 4, 0, 0, 0, 0, utc())
  # Subsequent occurrences add a calendar month to the previous occurrence.
  check beater.fireTime(some(previous), current).get() ==
    dateTime(2026, mMar, 1, 0, 0, 0, 0, utc())

test "IntervalBeater.fireTime | non-positive intervals retain existing behavior":
  let current = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  for seconds in [0, -10]:
    let interval = initTimeInterval(seconds=seconds)
    let past = current - initDuration(minutes=1)
    let future = current + initDuration(minutes=1)
    let pastBeater = initBeater(interval, dummyAsync, startTime=some(past))
    let futureBeater = initBeater(interval, dummyAsync, startTime=some(future))

    check pastBeater.fireTime(none(DateTime), current).get() == current
    check futureBeater.fireTime(none(DateTime), current).get() == future
    check pastBeater.fireTime(some(past), current).get() == past + interval

test "IntervalBeater.fireTime | endTime equal to next run is allowed":
  let current = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  let endTime = dateTime(2026, mJan, 1, 12, 5, 0, 0, utc())
  let beater = initBeater(
    initTimeInterval(minutes=10),
    dummyAsync,
    startTime=some(current - initTimeInterval(minutes=5)),
    endTime=some(endTime)
  )
  let actual = beater.fireTime(none(DateTime), current)
  check actual.isSome
  check actual.get == endTime

test "IntervalBeater.fireTime | endTime before next run stops scheduling":
  let current = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  let beater = initBeater(
    initTimeInterval(minutes=10),
    dummyAsync,
    startTime=some(current - initTimeInterval(minutes=5)),
    endTime=some(current + initTimeInterval(minutes=4))
  )
  check beater.fireTime(none(DateTime), current).isNone

test "IntervalBeater.fireTime | jitter":
  let current = now().utc()
  let beater = initBeater(
    initTimeInterval(seconds=10),
    dummyAsync,
    startTime=some(current + initTimeInterval(seconds=4)),
    jitter=initTimeInterval(seconds=5)
  )
  let base = current + initTimeInterval(seconds=4)
  let actual = beater.fireTime(none(DateTime), current).get()
  check actual >= base
  check actual <= base + initTimeInterval(seconds=5)

test "IntervalBeater.fireTime | jitter with previous run":
  let current = now().utc()
  let beater = initBeater(
    initTimeInterval(seconds=10),
    dummyAsync,
    jitter=initTimeInterval(seconds=5)
  )
  let prev = some(current)
  let base = current + initTimeInterval(seconds=10)
  let actual = beater.fireTime(prev, current).get()
  check actual >= base
  check actual <= base + initTimeInterval(seconds=5)

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

test "OnceBeater.fireTime":
  let scheduled = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
  let beater = initBeater(scheduled, dummyAsync)

  check beater.fireTime(none(DateTime), scheduled - initTimeInterval(hours=1)).get() == scheduled
  check beater.fireTime(some(scheduled), scheduled).isNone

test "OnceBeater.fireTime | pending deadlines remain available when due or overdue":
  let scheduled = dateTime(2026, mJan, 1, 12, 0, 0, 123_456_789, utc())
  let beater = initBeater(scheduled, dummyAsync)

  check beater.fireTime(none(DateTime), scheduled).get() == scheduled
  check beater.fireTime(none(DateTime), scheduled + initDuration(hours=1)).get() == scheduled
  check beater.fireTime(some(scheduled), scheduled + initDuration(hours=1)).isNone

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
  proc main(): bool =
    let target = now() + initDuration(microseconds=500)
    let callback: NextRunProc = proc(current: DateTime): Option[DateTime] {.
        gcsafe, raises: []
      .} =
      if current < target: some(target) else: none(DateTime)
    var launched = target - initDuration(seconds=1)
    let job: BeaterAsyncProc = proc(): Future[void] {.async.} =
      launched = now()
    let beater = initBeater(callback, job)

    waitFor beater.fire()
    result = launched >= target

  check main()

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

    while beater.nextRun.isNone:
      await sleepAsync(10)

    beater.pause()
    result = beater.state == bsPaused and beater.nextRun.isNone

    beater.stop()
    await fut

  check waitFor(main())

test "Beater.resume skips intervals missed while paused":
  pauseLaunches = 0

  proc main(): Future[bool] {.async.} =
    let current = now()
    let beater = initBeater(
      initTimeInterval(milliseconds=20),
      countedAsync,
      startTime=some(current),
      endTime=some(current + initTimeInterval(milliseconds=250)),
      id="skip-missed"
    )
    let fut = beater.fire()

    while pauseLaunches == 0:
      await sleepAsync(5)

    beater.pause()
    let launchesAtPause = pauseLaunches
    await sleepAsync(90)

    beater.resume()
    await sleepAsync(10)
    let launchesAfterResume = pauseLaunches

    beater.stop()
    await fut

    result = launchesAtPause == launchesAfterResume

  check waitFor(main())

test "Beater.resume before pending deadline recomputes next run":
  pauseLaunches = 0

  proc main(): Future[bool] {.async.} =
    let current = now()
    let beater = initBeater(
      initTimeInterval(milliseconds=120),
      countedAsync,
      startTime=some(current + initTimeInterval(milliseconds=120)),
      endTime=some(current + initTimeInterval(milliseconds=350)),
      id="resume-recomputes"
    )
    let fut = beater.fire()

    while beater.nextRun.isNone:
      await sleepAsync(5)

    beater.pause()
    await sleepAsync(20)
    beater.resume()
    await sleepAsync(70)

    result = pauseLaunches == 0

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

    while beater.nextRun.isNone:
      await sleepAsync(5)

    beater.pause()
    await sleepAsync(20)
    beater.resume()
    await sleepAsync(120)

    result = onceLaunches == 1 and beater.state == bsStopped

    beater.stop()
    await fut

  check waitFor(main())
