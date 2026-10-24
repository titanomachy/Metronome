## Disposable installed-package consumer; keep separate import modes so optional
## timer/timezone imports cannot hide an accidental dependency in the core.
## Copy this file outside the checkout before compiling, so tests/config.nims
## cannot add the checkout's src/ path. For each mode (core, scheduler, cron,
## timezones, timers), compile and run that copy with:
## nim c -r --threads:on --noNimblePath --skipUserCfg:on --skipParentCfg:on \
##   --skipProjCfg:on --path:<installed-package> -d:packageSmoke=<mode> \
##   --nimcache:<temporary-cache> --out:<temporary-binary> <copied-file>
## Inspect compiler dependencies for core/scheduler to exclude timers/timezones.

const packageSmoke {.strdefine.} = "core"

when packageSmoke in ["core", "scheduler", "timers"]:
  import std/[asyncdispatch, options, times]

  proc noop(): Future[void] {.async.} =
    discard

when packageSmoke == "core":
  import metronome

  static:
    doAssert not declared(intervalNextRun)
    doAssert not declared(withinEndTime)

  let current = dateTime(2026, mJan, 1, 12, 35, 0, 0, utc())
  let beater = initBeater(initTimeInterval(minutes=10), noop,
    startTime=some(dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())))
  doAssert beater.fireTime(none(DateTime), current).get() ==
    dateTime(2026, mJan, 1, 12, 40, 0, 0, utc())
  doAssert beater.nextRun().isNone

elif packageSmoke == "scheduler":
  import metronome/scheduler

  static:
    doAssert not declared(intervalNextRun)
    doAssert not declared(withinEndTime)

  let target = dateTime(2026, mJan, 1, 12, 0, 0, 123_456_789, utc())
  let callback: NextRunProc = proc (current: DateTime): Option[DateTime] {.
      gcsafe, raises: []
    .} =
    some(current + initDuration(microseconds=500))
  let beater = initBeater(callback, noop, startTime=some(target))
  doAssert beater.kind == bkCustom
  doAssert beater.fireTime(none(DateTime), target).get() ==
    target + initDuration(microseconds=500)

elif packageSmoke == "cron":
  import std/[options, times]
  import metronome/cron/cron

  let current = dateTime(2026, mJan, 1, 12, 35, 0, 0, utc())
  doAssert newCron(hour="13", minute="0").getNext(current).get() ==
    dateTime(2026, mJan, 1, 13, 0, 0, 0, utc())

elif packageSmoke == "timezones":
  import std/times
  import metronome/timezones

  doAssert timezoneDatabaseVersion() == "2026c"
  let zone = namedTimezone("Europe/Amsterdam")
  for (month, utcHour) in [(mJan, 11), (mJul, 10)]:
    doAssert dateTime(2026, month, 15, 12, 0, 0, 0, zone).utc ==
      dateTime(2026, month, 15, utcHour, 0, 0, 0, utc())

elif packageSmoke == "timers":
  import metronome
  import metronome/timers

  let current = dateTime(2026, mJan, 1, 12, 34, 0, 0, utc())
  let schedule = newTimer("*-*-* *:*:00.123456 UTC")
  let beater = initTimerBeater(schedule, noop, startTime=some(current))
  let target = current + initDuration(microseconds=123456)
  doAssert schedule.getNext(current).get() == target
  doAssert beater.fireTime(none(DateTime), current).get() == target
  scheduler jobs:
    timer(onCalendar="*-*-* *:*:00.123456 UTC", async=true):
      discard
  discard jobs

else:
  {.error: "packageSmoke must be core, scheduler, cron, timezones, or timers".}
