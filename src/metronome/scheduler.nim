## # Metronome
##
## A Nim scheduler library that lets you kick off jobs at regular intervals.
##
## Example usage::
##
##     metronome:
##       every(seconds=1, id="tick", throttle=1, async=true):
##         echo("async tick ", now())
##         await sleepAsync(2000)
##       every(seconds=1, id="sync tick", throttle=1):
##         echo("sync tick ", now())
##

import macros, options, times, asyncdispatch, sequtils, logging, random

from ./cron/cron import Cron, newCron, getNext

var logger* = newConsoleLogger() ## By default, the logger is attached to no handlers.
## If you want to show logs, please call `addHandler(logger)`.

type
  JobErrorHandler* = proc (fut: Future[void]) {.closure, gcsafe.}
  ## Handles a failed scheduled job future.

  BeaterAsyncProc* = proc (): Future[void] {.closure.}
  ## Async proc to be scheduled on the event-loop thread.

  BeaterThreadProc* = proc (): void {.gcsafe, thread.}
  ## Thread proc to be scheduled.
  ## It should be marked with pragma `{.thread.}`.
  ## It will be turned to BeaterAsyncProc in Metronome internally.

proc toAsync(p: BeaterThreadProc): BeaterAsyncProc =
  result =
    proc (): Future[void] {.gcsafe, closure, async.} =
      var thread: Thread[void]
      createThread(thread, p)
      while thread.running:
        await sleepAsync(10)
      joinThread(thread)

type
  Settings* = ref object
    appName*: string
    errorHandler*: JobErrorHandler

proc newSettings*(
  appName = "",
  errorHandler: JobErrorHandler = nil
): Settings =
  result = Settings(
    appName: appName,
    errorHandler: errorHandler
  )

type
  Throttler* = ref object ## Throttle the total number of beats.
    num: int
    beats: seq[Future[void]]

proc initThrottler*(num: int = 1): Throttler =
  ## Initialize the total number of beats allowed to be scheduled.
  ## By default, it's 1.
  ## If it's greater than 1, then more than one beats can be scheduled simultaneously.
  if num < 1:
    raise newException(ValueError, "throttle must be at least 1")
  var beats: seq[Future[void]] = @[]
  Throttler(num: num, beats: beats)

proc throttled*(self: Throttler): bool =
  ## Whether the throttler is allowed to schedule more beats.
  self.beats.keepItIf(not it.finished)
  result = self.beats.len >= self.num

proc submit*(self: Throttler, fut: Future[void]) =
  ## Submit a new future to the throttler.
  ## WARNING: this function does not perform throttling check.
  self.beats.add(fut)

type
  BeaterKind* {.pure.} = enum
    bkInterval
    bkCron
    bkOnce

  BeaterState* {.pure.} = enum
    bsRunning
    bsPaused
    bsStopped

  Beater* = ref object of RootObj ## Beater generates beats for the next runs.
    id: string
    startTime: DateTime
    endTime: Option[DateTime]
    beaterProc: BeaterAsyncProc
    throttler: Throttler
    state: BeaterState
    lastRunTime: Option[DateTime]
    nextRunTime: Option[DateTime]
    lastErrorRef: ref Exception
    lastErrorTime: Option[DateTime]
    failureCount: int
    errorHandler: JobErrorHandler
    runningBeats: int
    pauseGeneration: int
    resumeTime: Option[DateTime]
    jitterRand: Rand
    case kind*: BeaterKind
    of bkInterval:
      interval*: TimeInterval
      jitter*: TimeInterval
    of bkCron:
      cron*: Cron
      timezone*: Option[Timezone]
    of bkOnce:
      discard

proc `$`*(beater: Beater): string =
  case beater.kind
  of bkInterval:
    "Beater(" & $beater.kind & "," & $beater.interval & ")"
  of bkCron:
    "Beater(" & $beater.kind & "* * * * *" & ")"
  of bkOnce:
    "Beater(" & $beater.kind & "," & $beater.startTime & ")"

proc id*(beater: Beater): string =
  ## Return the identifier assigned to this beater.
  beater.id

proc state*(beater: Beater): BeaterState =
  ## Return the current lifecycle state for this beater.
  beater.state

proc lastRun*(beater: Beater): Option[DateTime] =
  ## Return the last time this beater launched a job.
  beater.lastRunTime

proc nextRun*(beater: Beater): Option[DateTime] =
  ## Return the next scheduled run time for this beater.
  beater.nextRunTime

proc lastError*(beater: Beater): ref Exception =
  ## Return the most recent job error, or nil if no job has failed.
  beater.lastErrorRef

proc lastErrorAt*(beater: Beater): Option[DateTime] =
  ## Return when this beater most recently recorded a job error.
  beater.lastErrorTime

proc failures*(beater: Beater): int =
  ## Return the number of job failures recorded for this beater.
  beater.failureCount

proc runningCount*(beater: Beater): int =
  ## Return the number of currently running jobs for this beater.
  beater.runningBeats

proc pause*(beater: Beater) =
  ## Pause future job launches for this beater.
  if beater.state != bsStopped:
    beater.state = bsPaused
    beater.nextRunTime = none(DateTime)
    beater.pauseGeneration.inc

proc resume*(beater: Beater) =
  ## Resume job launches for this beater.
  if beater.state == bsPaused:
    beater.state = bsRunning
    beater.resumeTime = some(now())

proc stop*(beater: Beater) =
  ## Stop this beater permanently.
  beater.state = bsStopped
  beater.nextRunTime = none(DateTime)

proc intervalMilliseconds(startTime: DateTime, interval: TimeInterval): int64 =
  (startTime + interval - startTime).inMilliseconds

proc newJitterRand(): Rand =
  let current = now()
  initRand(current.toTime.toUnix * 1_000_000 + current.nanosecond div 1_000)

proc applyJitter(self: Beater, fireTime: DateTime): DateTime =
  if self.kind != bkInterval:
    return fireTime

  let jitterMs = intervalMilliseconds(fireTime, self.jitter)
  if jitterMs <= 0:
    return fireTime

  let maxOffsetMs = min(jitterMs, int64(high(int)))
  result = fireTime + initDuration(milliseconds=self.jitterRand.rand(int(maxOffsetMs)))

proc initBeater*(
  interval: TimeInterval,
  asyncProc: BeaterAsyncProc,
  startTime: Option[DateTime] = none(DateTime),
  endTime: Option[DateTime] = none(DateTime),
  id: string = "",
  throttleNum: int = 1,
  errorHandler: JobErrorHandler = nil,
  jitter: TimeInterval = initTimeInterval(),
): Beater =
  ## Initialize a Beater, which kind is bkInterval.
  ##
  ## startTime, endTime, and jitter are optional. Jitter adds a random
  ## non-negative delay to each interval launch without changing the base
  ## interval cadence.
  Beater(
    id: id,
    kind: bkInterval,
    interval: interval,
    jitter: jitter,
    beaterProc: asyncProc,
    throttler: initThrottler(num=throttleNum),
    state: bsRunning,
    lastRunTime: none(DateTime),
    nextRunTime: none(DateTime),
    lastErrorRef: nil,
    lastErrorTime: none(DateTime),
    failureCount: 0,
    errorHandler: errorHandler,
    runningBeats: 0,
    pauseGeneration: 0,
    resumeTime: none(DateTime),
    jitterRand: newJitterRand(),
    startTime: if startTime.isSome: startTime.get() else: now(),
    endTime: endTime,
  )

proc initBeater*(
  interval: TimeInterval,
  threadProc: BeaterThreadProc,
  startTime: Option[DateTime] = none(DateTime),
  endTime: Option[DateTime] = none(DateTime),
  id: string = "",
  throttleNum: int = 1,
  errorHandler: JobErrorHandler = nil,
  jitter: TimeInterval = initTimeInterval(),
): Beater =
  ## Initialize a Beater, which kind is bkInterval.
  ##
  ## startTime, endTime, and jitter are optional. Jitter adds a random
  ## non-negative delay to each interval launch without changing the base
  ## interval cadence.
  if errorHandler != nil:
    raise newException(ValueError, "thread-backed beaters do not support error handlers")
  Beater(
    id: id,
    kind: bkInterval,
    interval: interval,
    jitter: jitter,
    beaterProc: threadProc.toAsync,
    throttler: initThrottler(num=throttleNum),
    state: bsRunning,
    lastRunTime: none(DateTime),
    nextRunTime: none(DateTime),
    lastErrorRef: nil,
    lastErrorTime: none(DateTime),
    failureCount: 0,
    errorHandler: errorHandler,
    runningBeats: 0,
    pauseGeneration: 0,
    resumeTime: none(DateTime),
    jitterRand: newJitterRand(),
    startTime: if startTime.isSome: startTime.get() else: now(),
    endTime: endTime,
  )

proc initBeater*(
  cron: Cron,
  threadProc: BeaterThreadProc,
  startTime: Option[DateTime] = none(DateTime),
  endTime: Option[DateTime] = none(DateTime),
  id: string = "",
  throttleNum: int = 1,
  errorHandler: JobErrorHandler = nil,
  timezone: Option[Timezone] = none(Timezone),
): Beater =
  ## Initialize a Beater, which kind is bkCron.
  ##
  ## startTime, endTime, and timezone are optional. When timezone is set, cron
  ## matching is evaluated in that timezone and converted back to the caller's
  ## timezone for scheduling.
  if errorHandler != nil:
    raise newException(ValueError, "thread-backed beaters do not support error handlers")
  Beater(
    id: id,
    kind: bkCron,
    cron: cron,
    timezone: timezone,
    beaterProc: threadProc.toAsync,
    throttler: initThrottler(num=throttleNum),
    state: bsRunning,
    lastRunTime: none(DateTime),
    nextRunTime: none(DateTime),
    lastErrorRef: nil,
    lastErrorTime: none(DateTime),
    failureCount: 0,
    errorHandler: errorHandler,
    runningBeats: 0,
    pauseGeneration: 0,
    resumeTime: none(DateTime),
    jitterRand: newJitterRand(),
    startTime: if startTime.isSome: startTime.get() else: now(),
    endTime: endTime,
  )

proc initBeater*(
  cron: Cron,
  asyncProc: BeaterAsyncProc,
  startTime: Option[DateTime] = none(DateTime),
  endTime: Option[DateTime] = none(DateTime),
  id: string = "",
  throttleNum: int = 1,
  errorHandler: JobErrorHandler = nil,
  timezone: Option[Timezone] = none(Timezone),
): Beater =
  ## Initialize a Beater, which kind is bkCron.
  ##
  ## startTime, endTime, and timezone are optional. When timezone is set, cron
  ## matching is evaluated in that timezone and converted back to the caller's
  ## timezone for scheduling.
  Beater(
    id: id,
    kind: bkCron,
    cron: cron,
    timezone: timezone,
    beaterProc: asyncProc,
    throttler: initThrottler(num=throttleNum),
    state: bsRunning,
    lastRunTime: none(DateTime),
    nextRunTime: none(DateTime),
    lastErrorRef: nil,
    lastErrorTime: none(DateTime),
    failureCount: 0,
    errorHandler: errorHandler,
    runningBeats: 0,
    pauseGeneration: 0,
    resumeTime: none(DateTime),
    jitterRand: newJitterRand(),
    startTime: if startTime.isSome: startTime.get() else: now(),
    endTime: endTime,
  )

proc initBeater*(
  time: DateTime,
  asyncProc: BeaterAsyncProc,
  id: string = "",
  throttleNum: int = 1,
  errorHandler: JobErrorHandler = nil,
): Beater =
  ## Initialize a one-shot Beater, which launches once at time.
  Beater(
    id: id,
    kind: bkOnce,
    beaterProc: asyncProc,
    throttler: initThrottler(num=throttleNum),
    state: bsRunning,
    lastRunTime: none(DateTime),
    nextRunTime: none(DateTime),
    lastErrorRef: nil,
    lastErrorTime: none(DateTime),
    failureCount: 0,
    errorHandler: errorHandler,
    runningBeats: 0,
    pauseGeneration: 0,
    resumeTime: none(DateTime),
    jitterRand: newJitterRand(),
    startTime: time,
    endTime: none(DateTime),
  )

proc initBeater*(
  time: DateTime,
  threadProc: BeaterThreadProc,
  id: string = "",
  throttleNum: int = 1,
  errorHandler: JobErrorHandler = nil,
): Beater =
  ## Initialize a one-shot Beater, which launches once at time.
  if errorHandler != nil:
    raise newException(ValueError, "thread-backed beaters do not support error handlers")
  Beater(
    id: id,
    kind: bkOnce,
    beaterProc: threadProc.toAsync,
    throttler: initThrottler(num=throttleNum),
    state: bsRunning,
    lastRunTime: none(DateTime),
    nextRunTime: none(DateTime),
    lastErrorRef: nil,
    lastErrorTime: none(DateTime),
    failureCount: 0,
    errorHandler: errorHandler,
    runningBeats: 0,
    pauseGeneration: 0,
    resumeTime: none(DateTime),
    jitterRand: newJitterRand(),
    startTime: time,
    endTime: none(DateTime),
  )

proc nominalFireTime(
  self: Beater,
  prev: Option[DateTime],
  now: DateTime
): Option[DateTime] =
  result = case self.kind
  of bkInterval:
    some(
      if prev.isNone:
        if self.startTime >= now:
          self.startTime
        else:
          let passedMs = (now - self.startTime).inMilliseconds
          let intervalLen = intervalMilliseconds(self.startTime, self.interval)
          if intervalLen <= 0:
            now
          else:
            let leftMs = intervalLen - passedMs mod intervalLen
            now + initDuration(milliseconds=leftMs)
      else:
        prev.get() + self.interval
    )
  of bkCron:
    if self.timezone.isSome:
      let zonedNow = now.inZone(self.timezone.get())
      let zonedNext = self.cron.getNext(zonedNow)
      if zonedNext.isSome:
        some(zonedNext.get().toTime.inZone(now.timezone))
      else:
        none(DateTime)
    else:
      self.cron.getNext(now)
  of bkOnce:
    if prev.isNone:
      some(self.startTime)
    else:
      none(DateTime)

  if self.endTime.isSome and result.isSome and result.get() > self.endTime.get():
    result = none(DateTime)

proc fireTime*(
  self: Beater,
  prev: Option[DateTime],
  now: DateTime
): Option[DateTime] =
  ## Returns the next fire time of a task execution.
  ##
  ## For bkInterval, it uses these rules:
  ##
  ## * For the 1st run,
  ##   * Choose `startTime` when it is equal to or later than `now`.
  ##   * Choose the next future `startTime + N * interval` when `startTime`
  ##     is earlier than `now`.
  ## * For the rest of runs,
  ##   * Choose `prev + interval`.
  ##
  ## Cron beaters delegate to cron matching, optionally in their configured
  ## timezone. One-shot beaters return their scheduled time only while `prev`
  ## is none.
  ##
  ## If `self.endTime` is set and the computed fire time is later than it,
  ## none(DateTime) is returned. A fire time exactly equal to `endTime` is still
  ## allowed.
  result = self.nominalFireTime(prev, now)

  if result.isSome:
    result = some(self.applyJitter(result.get()))

  if self.endTime.isSome and result.isSome and result.get() > self.endTime.get():
    result = none(DateTime)

proc waitUntil(
  self: Beater,
  whenToRun: DateTime,
  pauseGeneration: int
): Future[bool] {.async.} =
  while self.state notin {bsPaused, bsStopped} and
      self.pauseGeneration == pauseGeneration:
    let sleepDuration = whenToRun - now()
    let sleepMs = cast[int](sleepDuration.inMilliseconds)
    if sleepMs <= 0:
      return true
    await sleepAsync(min(sleepMs, 100))
  result = false

proc watch(self: Beater, fut: Future[void], errorHandler: JobErrorHandler) =
  self.runningBeats.inc
  fut.addCallback(
    proc (fut: Future[void]) {.gcsafe.} =
      if self.runningBeats > 0:
        self.runningBeats.dec
      if fut.failed:
        self.lastErrorRef = fut.readError()
        self.lastErrorTime = some(now())
        self.failureCount.inc
        let handler = if self.errorHandler != nil: self.errorHandler else: errorHandler
        if handler != nil:
          try:
            handler(fut)
          except CatchableError as exc:
            error("\"", self.id, "\" error handler failed: ", exc.msg)
        else:
          error("\"", self.id, "\" failed: ", self.lastErrorRef.msg)
  )

proc failedJobFuture(exc: ref Exception): Future[void] =
  result = newFuture[void]("metronome.failedJobFuture")
  result.fail(exc)

proc launch(self: Beater): Future[void] =
  ## Normalize failures raised while invoking a job to failed futures so they
  ## follow the same tracking, throttling, and error-handler path as async
  ## failures.
  try:
    result = self.beaterProc()
    if result.isNil:
      result = failedJobFuture(
        newException(ValueError, "scheduled job returned a nil future")
      )
  except CatchableError as exc:
    result = failedJobFuture(exc)

proc fire*(
  self: Beater,
  errorHandler: JobErrorHandler = nil
) {.async.} =
  ## Fire beats as async loop until no beats can be scheduled.
  var prev = none(DateTime)
  var nextRunTime = none(DateTime)
  while self.state != bsStopped:
    if self.state == bsPaused:
      await sleepAsync(100)
      continue

    if self.resumeTime.isSome:
      if self.kind == bkInterval:
        prev = self.resumeTime
      self.resumeTime = none(DateTime)

    let nominalRunTime = self.nominalFireTime(prev, now())
    if nominalRunTime.isNone:
      self.nextRunTime = none(DateTime)
      break

    nextRunTime = some(self.applyJitter(nominalRunTime.get()))
    if self.endTime.isSome and nextRunTime.get() > self.endTime.get():
      self.nextRunTime = none(DateTime)
      break

    self.nextRunTime = nextRunTime
    let pauseGeneration = self.pauseGeneration
    let reachedRunTime = await waitUntil(self, nextRunTime.get(), pauseGeneration)
    if not reachedRunTime:
      prev = none(DateTime)
      continue
    if self.state == bsStopped:
      continue

    if not self.throttler.throttled:
      let fut = self.launch()
      self.lastRunTime = some(now())
      self.throttler.submit(fut)
      self.watch(fut, errorHandler)
      prev = nominalRunTime
      if self.kind == bkOnce:
        self.stop()
    else:
      debug("\"", self.id, "\" is trottled. Maximum num is ", self.throttler.num, ".")
      prev = nominalRunTime

type
  Scheduler* = ref object
    settings: Settings
    beaters: seq[Beater]
    futures: seq[Future[void]]

proc initScheduler*(settings: Settings): Scheduler =
  ## Initialize a scheduler.
  var beaters: seq[Beater] = @[]
  var futures: seq[Future[void]] = @[]
  result = Scheduler(
    settings: if settings.isNil: newSettings() else: settings,
    beaters: beaters,
    futures: futures,
  )

proc findBeater(self: Scheduler, id: string): Beater =
  if id.len == 0:
    return nil
  var matches = 0
  for beater in self.beaters:
    if beater.id == id:
      result = beater
      matches.inc
  if matches != 1:
    return nil

proc register*(self: Scheduler, beater: Beater) =
  ## Register a beater.
  self.beaters.add(beater)

proc listJobs*(self: Scheduler): seq[string] =
  ## Return all non-empty registered job identifiers.
  for beater in self.beaters:
    if beater.id.len > 0:
      result.add(beater.id)

proc pause*(self: Scheduler, id: string): bool =
  ## Pause a registered job by identifier.
  let beater = self.findBeater(id)
  if beater.isNil:
    return false
  beater.pause()
  result = true

proc resume*(self: Scheduler, id: string): bool =
  ## Resume a registered job by identifier.
  let beater = self.findBeater(id)
  if beater.isNil:
    return false
  beater.resume()
  result = true

proc stop*(self: Scheduler, id: string): bool =
  ## Stop a registered job by identifier.
  let beater = self.findBeater(id)
  if beater.isNil:
    return false
  beater.stop()
  result = true

proc stopAll*(self: Scheduler) =
  ## Stop all registered jobs.
  for beater in self.beaters:
    beater.stop()

proc jobState*(self: Scheduler, id: string): Option[BeaterState] =
  ## Return the lifecycle state for a registered job.
  let beater = self.findBeater(id)
  if beater.isNil:
    return none(BeaterState)
  result = some(beater.state)

proc lastRun*(self: Scheduler, id: string): Option[DateTime] =
  ## Return the last run time for a registered job.
  let beater = self.findBeater(id)
  if beater.isNil:
    return none(DateTime)
  result = beater.lastRun

proc nextRun*(self: Scheduler, id: string): Option[DateTime] =
  ## Return the next run time for a registered job.
  let beater = self.findBeater(id)
  if beater.isNil:
    return none(DateTime)
  result = beater.nextRun

proc lastError*(self: Scheduler, id: string): ref Exception =
  ## Return the most recent error for a registered job, or nil.
  let beater = self.findBeater(id)
  if beater.isNil:
    return nil
  result = beater.lastError

proc lastErrorAt*(self: Scheduler, id: string): Option[DateTime] =
  ## Return when a registered job most recently recorded an error.
  let beater = self.findBeater(id)
  if beater.isNil:
    return none(DateTime)
  result = beater.lastErrorAt

proc failures*(self: Scheduler, id: string): int =
  ## Return the number of failures recorded for a registered job.
  let beater = self.findBeater(id)
  if beater.isNil:
    return 0
  result = beater.failures

proc runningCount*(self: Scheduler, id: string): int =
  ## Return the number of currently running jobs for a registered job.
  let beater = self.findBeater(id)
  if beater.isNil:
    return 0
  result = beater.runningCount

proc idle*(self: Scheduler) {.async.} =
  ## Idle the scheduler. It prevents the scheduler from shutdown when no beats is running.
  while true:
    await sleepAsync(1000)

proc start*(self: Scheduler) {.async.} =
  ## Start the scheduler.
  for beater in self.beaters:
    let fut = fire(beater, self.settings.errorHandler)
    self.futures.add(fut)
    asyncCheck fut

proc serve*(self: Scheduler) =
  ## Serve the scheduler. It's a blocking function.
  asyncCheck idle(self)
  asyncCheck start(self)
  runForever()

proc waitFor*(self: Scheduler) =
  ## Run all beats til they're completed.
  waitFor start(self)

proc parseCron(call: NimNode): tuple[
  async: bool,
  id: NimNode,
  throttleNum: NimNode,
  body: NimNode,
  startTime: NimNode,
  endTime: NimNode,
  errorHandler: NimNode,
  timezone: NimNode,
  year: NimNode,
  month: NimNode,
  day_of_month: NimNode,
  day_of_week: NimNode,
  hour: NimNode,
  minute: NimNode,
] =
  var async: bool = false
  var id = newLit("")
  var throttleNum = newLit(1)
  var startTime = newCall(bindSym("none"), ident("DateTime"))
  var endTime = newCall(bindSym("none"), ident("DateTime"))
  var errorHandler = newNilLit()
  var timezone = newCall(bindSym("none"), ident("Timezone"))
  var year, month, day_of_week, day_of_month, hour, minute  = newLit("*")
  let body = call[call.len-1]
  body.expectKind nnkStmtList
  for e in call[1 ..< call.len-1]:
    e.expectKind nnkExprEqExpr
    case e[0].`$`
    of "async": async = e[1].`$` == "true"
    of "id": id = e[1]
    of "throttle": throttleNum = e[1]
    of "startTime": startTime = newCall(bindSym("some"), e[1])
    of "endTime": endTime = newCall(bindSym("some"), e[1])
    of "onError": errorHandler = e[1]
    of "timezone": timezone = newCall(bindSym("some"), e[1])
    of "year": year = e[1]
    of "month": month = e[1]
    of "day_of_month": day_of_month = e[1]
    of "day_of_week": day_of_week = e[1]
    of "hour": hour = e[1]
    of "minute": minute = e[1]
    else: macros.error("unexpected parameter for `cron`: " & e[0].`$`, call)
  result = (
    async: async,
    id: id,
    throttleNum: throttleNum,
    body: body,
    startTime: startTime,
    endTime: endTime,
    errorHandler: errorHandler,
    timezone: timezone,
    year: year,
    month: month,
    day_of_month: day_of_month,
    day_of_week: day_of_week,
    hour: hour,
    minute: minute,
  )

proc processCron(call: NimNode): NimNode=
  let (asyncProc, id, throttleNum, procBody, startTime, endTime, errorHandler, timezone, year, month, day_of_month, day_of_week, hour, minute) = parseCron(call)
  let cron = quote do:
    newCron(year=`year`, month=`month`, day_of_month=`day_of_month`, day_of_week=`day_of_week`, hour=`hour`, minute=`minute`)
  if asyncProc:
    result = quote do:
      initBeater(
        id = `id`,
        cron = `cron`,
        throttleNum = `throttleNum`,
        startTime = `startTime`,
        endTime = `endTime`,
        errorHandler = `errorHandler`,
        timezone = `timezone`,
        asyncProc = proc() {.async.} =
          `procBody`
      )
  else:
    if errorHandler.kind != nnkNilLit:
      macros.error("`onError` is only supported for async cron jobs", call)
    result = quote do:
      initBeater(
        id = `id`,
        cron = `cron`,
        throttleNum = `throttleNum`,
        startTime = `startTime`,
        endTime = `endTime`,
        errorHandler = `errorHandler`,
        timezone = `timezone`,
        threadProc = proc() {.thread.} =
          `procBody`
      )

proc parseAt(call: NimNode): tuple[
  async: bool,
  id: NimNode,
  throttleNum: NimNode,
  body: NimNode,
  time: NimNode,
  errorHandler: NimNode,
] =
  var async: bool = false
  var id = newLit("")
  var throttleNum = newLit(1)
  var time = newEmptyNode()
  var errorHandler = newNilLit()
  let body = call[call.len-1]
  body.expectKind nnkStmtList
  for e in call[1 ..< call.len-1]:
    e.expectKind nnkExprEqExpr
    case e[0].`$`
    of "async": async = e[1].`$` == "true"
    of "id": id = e[1]
    of "throttle": throttleNum = e[1]
    of "time": time = e[1]
    of "onError": errorHandler = e[1]
    else: macros.error("unexpected parameter for `at`: " & e[0].`$`, call)
  if time.kind == nnkEmpty:
    macros.error("missing required parameter for `at`: time", call)
  result = (
    async: async,
    id: id,
    throttleNum: throttleNum,
    body: body,
    time: time,
    errorHandler: errorHandler,
  )

proc processAt(call: NimNode): NimNode =
  let (asyncProc, id, throttleNum, procBody, time, errorHandler) = parseAt(call)
  if asyncProc:
    result = quote do:
      initBeater(
        id = `id`,
        time = `time`,
        throttleNum = `throttleNum`,
        errorHandler = `errorHandler`,
        asyncProc = proc() {.async.} =
          `procBody`
      )
  else:
    if errorHandler.kind != nnkNilLit:
      macros.error("`onError` is only supported for async one-shot jobs", call)
    result = quote do:
      initBeater(
        id = `id`,
        time = `time`,
        throttleNum = `throttleNum`,
        threadProc = proc() {.thread.} =
          `procBody`
      )

proc parseEvery(call: NimNode): tuple[
  async: bool,
  id: NimNode,
  throttleNum: NimNode,
  body: NimNode,
  milliseconds: NimNode,
  seconds: NimNode,
  minutes: NimNode,
  hours: NimNode,
  days: NimNode,
  weeks: NimNode,
  months: NimNode,
  years: NimNode,
  startTime: NimNode,
  endTime: NimNode,
  errorHandler: NimNode,
  jitter: NimNode,
] =
  var async: bool = false
  var id = newLit("")
  var throttleNum = newLit(1)
  var startTime = newCall(bindSym("none"), ident("DateTime"))
  var endTime = newCall(bindSym("none"), ident("DateTime"))
  var errorHandler = newNilLit()
  var jitter = newCall(bindSym("initTimeInterval"))
  var years, months, weeks, days, hours, minutes, seconds, milliseconds = newLit(0)
  let body = call[call.len-1]
  body.expectKind nnkStmtList
  for e in call[1 ..< call.len-1]:
    e.expectKind nnkExprEqExpr
    case e[0].`$`
    of "async": async = e[1].`$` == "true"
    of "id": id = e[1]
    of "throttle": throttleNum = e[1]
    of "years": years = e[1]
    of "months": months = e[1]
    of "weeks": weeks = e[1]
    of "days": days = e[1]
    of "hours": hours = e[1]
    of "minutes": minutes = e[1]
    of "seconds": seconds = e[1]
    of "milliseconds": milliseconds = e[1]
    of "startTime": startTime = newCall(bindSym("some"), e[1])
    of "endTime": endTime = newCall(bindSym("some"), e[1])
    of "onError": errorHandler = e[1]
    of "jitter": jitter = e[1]
    else: macros.error("unexpected parameter for `every`: " & e[0].`$`, call)
  result = (
    async: async,
    id: id,
    throttleNum: throttleNum,
    body: body,
    milliseconds: milliseconds,
    seconds: seconds,
    minutes: minutes,
    hours: hours,
    days: days,
    weeks: weeks,
    months: months,
    years: years,
    startTime: startTime,
    endTime: endTime,
    errorHandler: errorHandler,
    jitter: jitter,
  )

proc processEvery(call: NimNode): NimNode=
  let (asyncProc, id, throttleNum, procBody, milliseconds, seconds,
    minutes, hours, days, weeks, months, years, startTime, endTime, errorHandler, jitter) = parseEvery(call)
  let interval = quote do:
    initTimeInterval(
      years=`years`, months=`months`, weeks=`weeks`, days=`days`, hours=`hours`,
      minutes=`minutes`, seconds=`seconds`, milliseconds=`milliseconds`,
    )
  if asyncProc:
    result = quote do:
      initBeater(
        id = `id`,
        interval = `interval`,
        throttleNum = `throttleNum`,
        startTime = `startTime`,
        endTime = `endTime`,
        errorHandler = `errorHandler`,
        jitter = `jitter`,
        asyncProc = proc() {.async.} =
          `procBody`
      )
  else:
    if errorHandler.kind != nnkNilLit:
      macros.error("`onError` is only supported for async interval jobs", call)
    result = quote do:
      initBeater(
        id = `id`,
        interval = `interval`,
        throttleNum = `throttleNum`,
        startTime = `startTime`,
        endTime = `endTime`,
        errorHandler = `errorHandler`,
        jitter = `jitter`,
        threadProc = proc() {.thread.} =
          `procBody`
      )

proc processSchedule(call: NimNode): NimNode =
  call.expectKind nnkCall
  let cmdName = call[0].`$`
  case cmdName
  of "every": processEvery(call)
  of "cron": processCron(call)
  of "at": processAt(call)
  else: raise newException(Exception, "unknown cmd: " & cmdName)

proc schedulerEx(sched: NimNode, body: NimNode): NimNode =
  if sched.kind != nnkIdent: macros.error(
    "Need an indent after macro `router`.", sched
  )

  body.expectKind nnkStmtList

  result = newStmtList()
  result.add(quote do:
    var `sched` = initScheduler(newSettings())
  )
  for call in body:
    let beaterNode = processSchedule(call)
    result.add(quote do:
      `sched`.register(`beaterNode`)
    )

macro scheduler*(sched: untyped, body: untyped) =
  ## Initialize a scheduler and register code blocks as beats.
  ##
  ## Use it when running Metronome alongside another event-driven library,
  ## such as a web framework.
  result = schedulerEx(sched, body)

macro metronome*(body: untyped): untyped =
  ## Initialize a scheduler, register code blocks as beats,
  ## and run it as a blocking application.
  ##
  ## You'll use it when the scheduled jobs are the only thing
  ## your programm will need to handle.
  let ident = newIdentNode("scheduler")
  result = schedulerEx(ident, body)
  result.add(quote do:
    `ident`.serve()
  )
