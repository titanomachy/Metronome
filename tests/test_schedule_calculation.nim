## Nominal calculations need explicit dates, not jobs or an event loop.
## Jitter and execution-state compatibility are tested in test_beater.nim.
import std/[options, times, unittest]
import metronome/private/schedule
from metronome/cron/cron import newCron

proc fixedTimezone(name: string, offset: int): Timezone =
  # std/times offsets are seconds west of UTC; no host zoneinfo is consulted.
  proc fromTime(time: Time): ZonedTime =
    ZonedTime(time: time, utcOffset: offset, isDst: false)
  proc fromAdjTime(time: Time): ZonedTime =
    ZonedTime(time: time + initDuration(seconds=offset),
      utcOffset: offset, isDst: false)
  newTimezone(name, fromTime, fromAdjTime)

suite "Nominal interval calculation":
  test "initial queries include a start at or after the current time":
    let start = dateTime(2026, mJan, 1, 12, 0, 0, 123_456_789, utc())
    let interval = initTimeInterval(seconds=10)
    for current in [start - initDuration(seconds=4), start]:
      check intervalNextRun(interval, start, none(DateTime), current) == some(start)

  test "past starts align after missed time and advance at exact boundaries":
    let start = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
    let interval = initTimeInterval(minutes=10)
    for (elapsed, nextMinute) in [(4, 10), (14, 20), (30, 40), (35, 40)]:
      let current = start + initDuration(minutes=elapsed)
      check intervalNextRun(interval, start, none(DateTime), current) ==
        some(dateTime(2026, mJan, 1, 12, nextMinute, 0, 0, utc()))

  test "previous nominal times advance even when still behind current time":
    let start = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
    let current = start + initDuration(minutes=30)
    let interval = initTimeInterval(minutes=10)
    check intervalNextRun(interval, start, none(DateTime), current) ==
      some(dateTime(2026, mJan, 1, 12, 40, 0, 0, utc()))
    for anchor in [start, current + initDuration(days=1)]:
      check intervalNextRun(interval, anchor, some(start), current) ==
        some(dateTime(2026, mJan, 1, 12, 10, 0, 0, utc()))
      check intervalNextRun(interval, anchor, some(current), current) ==
        some(dateTime(2026, mJan, 1, 12, 40, 0, 0, utc()))

  test "calendar months retain distinct initial and subsequent arithmetic":
    let start = dateTime(2026, mJan, 1, 0, 0, 0, 0, utc())
    let current = dateTime(2026, mFeb, 15, 0, 0, 0, 0, utc())
    let previous = dateTime(2026, mFeb, 1, 0, 0, 0, 0, utc())
    let interval = initTimeInterval(months=1)
    # Initial alignment uses January's 31-day length, not successive months.
    check intervalMilliseconds(start, interval) == 31'i64 * 86_400_000
    check intervalNextRun(interval, start, none(DateTime), current) ==
      some(dateTime(2026, mMar, 4, 0, 0, 0, 0, utc()))
    check intervalNextRun(interval, start, some(previous), current) ==
      some(dateTime(2026, mMar, 1, 0, 0, 0, 0, utc()))

  test "non-positive intervals keep initial and previous-occurrence behavior":
    let current = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
    let past = current - initDuration(minutes=1)
    let future = current + initDuration(minutes=1)
    for seconds in [0, -10]:
      let interval = initTimeInterval(seconds=seconds)
      check intervalNextRun(interval, past, none(DateTime), current) == some(current)
      check intervalNextRun(interval, future, none(DateTime), current) == some(future)
      check intervalNextRun(interval, past, some(past), current) ==
        some(past + initDuration(seconds=seconds))

  test "initial alignment retains fractional milliseconds across year rollover":
    let start = dateTime(2026, mDec, 31, 23, 59, 59, 973_456_789, utc())
    let current = start + initDuration(milliseconds=25, nanoseconds=321_000)
    let interval = initTimeInterval(milliseconds=10)
    # Whole-millisecond measurement retains the query's remaining fraction.
    check intervalNextRun(interval, start, none(DateTime), current) ==
      some(dateTime(2027, mJan, 1, 0, 0, 0, 3_777_789, utc()))
    check intervalNextRun(interval, start, some(start), current) ==
      some(dateTime(2026, mDec, 31, 23, 59, 59, 983_456_789, utc()))

  test "sub-millisecond intervals preserve precise previous progression":
    let start = dateTime(2026, mJan, 1, 12, 0, 0, 123_456_789, utc())
    let current = start + initDuration(seconds=1)
    let interval = initTimeInterval(microseconds=500)
    check intervalMilliseconds(start, interval) == 0
    check intervalNextRun(interval, start, none(DateTime), current) == some(current)
    for query in [start, start - initDuration(seconds=1)]:
      check intervalNextRun(interval, start, none(DateTime), query) == some(start)
    check intervalNextRun(interval, start, some(start), current) ==
      some(dateTime(2026, mJan, 1, 12, 0, 0, 123_956_789, utc()))

  test "leap years retain anchor length and calendar progression":
    let monthStart = dateTime(2024, mFeb, 1, 0, 0, 0, 0, utc())
    let monthCurrent = dateTime(2024, mMar, 1, 0, 0, 0, 0, utc())
    let monthly = initTimeInterval(months=1)
    check intervalMilliseconds(monthStart, monthly) == 29'i64 * 86_400_000
    check intervalNextRun(monthly, monthStart, none(DateTime), monthCurrent) ==
      some(dateTime(2024, mMar, 30, 0, 0, 0, 0, utc()))
    check intervalNextRun(monthly, monthStart, some(monthCurrent), monthCurrent) ==
      some(dateTime(2024, mApr, 1, 0, 0, 0, 0, utc()))

    let yearStart = dateTime(2023, mJan, 1, 0, 0, 0, 0, utc())
    let yearCurrent = dateTime(2024, mJul, 1, 0, 0, 0, 0, utc())
    let yearly = initTimeInterval(years=1)
    check intervalNextRun(yearly, yearStart, none(DateTime), yearCurrent) ==
      some(dateTime(2024, mDec, 31, 0, 0, 0, 0, utc()))
    check intervalNextRun(yearly, yearStart,
      some(dateTime(2024, mJan, 1, 0, 0, 0, 0, utc())), yearCurrent) ==
      some(dateTime(2025, mJan, 1, 0, 0, 0, 0, utc()))

  test "calendar progression crosses leap days and month/year boundaries":
    let leapDay = dateTime(2024, mFeb, 29, 23, 0, 0, 0, utc())
    check intervalNextRun(initTimeInterval(days=1), leapDay, some(leapDay),
      leapDay) == some(dateTime(2024, mMar, 1, 23, 0, 0, 0, utc()))
    let december = dateTime(2026, mDec, 1, 0, 0, 0, 0, utc())
    check intervalNextRun(initTimeInterval(months=1), december, some(december),
      december) == some(dateTime(2027, mJan, 1, 0, 0, 0, 0, utc()))

suite "Nominal cron calculation":
  test "unconfigured and UTC-configured queries keep matching boundaries":
    let current = dateTime(2026, mJan, 1, 11, 30, 0, 0, utc())
    let target = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
    let cron = newCron(hour="12", minute="0")
    for zone in [none(Timezone), some(utc())]:
      check cronNextRun(cron, zone, current) == some(target)
      # Cron includes an already matching minute; it is not strictly later.
      check cronNextRun(cron, zone, target) == some(target)

  test "configured zones return in the caller zone without host timezone data":
    let callerZone = fixedTimezone("Test/UTC-05", 5 * 3600)
    let scheduleZone = fixedTimezone("Test/UTC+02", -2 * 3600)
    let current = dateTime(2026, mJan, 1, 6, 30, 0, 0, callerZone)
    let cron = newCron(hour="14", minute="0")
    let actual = cronNextRun(cron, some(scheduleZone), current).get()
    check actual == dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
    check actual.hour == 7
    check actual.timezone == callerZone
    let callerNext = cronNextRun(newCron(hour="12", minute="0"),
      none(Timezone), current).get()
    check callerNext == dateTime(2026, mJan, 1, 17, 0, 0, 0, utc())
    check callerNext.timezone == callerZone

suite "Nominal custom and one-shot calculation":
  test "custom queries include an exact future lower bound and preserve precision":
    proc main() =
      let current = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
      let start = current + initDuration(seconds=1, nanoseconds=123_456_789)
      var queries: seq[DateTime]
      let callback = proc(query: DateTime): Option[DateTime] {.
          gcsafe, raises: []
        .} =
        queries.add(query)
        some(query + initDuration(nanoseconds=1))
      check customNextRun(callback, start, current) == some(start)
      check customNextRun(callback, start, start) ==
        some(start + initDuration(nanoseconds=1))
      let later = start + initDuration(microseconds=500)
      check customNextRun(callback, start, later) ==
        some(later + initDuration(nanoseconds=1))
      check queries == @[start - initDuration(nanoseconds=1), start, later]
    main()

  test "stateful custom callbacks are invoked once and may exhaust":
    proc main() =
      let current = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
      let targetZone = fixedTimezone("Test/UTC+0545", -(5 * 3600 + 45 * 60))
      let target = (current + initDuration(microseconds=500,
        nanoseconds=123)).inZone(targetZone)
      var queries: seq[DateTime]
      let callback = proc(query: DateTime): Option[DateTime] {.
          gcsafe, raises: []
        .} =
        queries.add(query)
        if queries.len == 1: some(target) else: none(DateTime)
      let actual = customNextRun(callback, current, current).get()
      check actual == target
      check actual.nanosecond == 500_123
      check actual.timezone == targetZone
      check queries == @[current]
      # Identical inputs need not repeat a user callback's result.
      check customNextRun(callback, current, current).isNone
      check queries == @[current, current]
    main()

  test "an empty custom schedule has no candidate for any start position":
    let current = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
    let empty = proc(query: DateTime): Option[DateTime] {.
        gcsafe, raises: []
      .} = none(DateTime)
    for start in [current - initDuration(days=1), current,
        current + initDuration(days=1)]:
      check customNextRun(empty, start, current).isNone

  test "pending one-shots retain past, present, and future precise deadlines":
    let current = dateTime(2026, mJan, 1, 12, 0, 0, 123_456_789, utc())
    let zone = fixedTimezone("Test/UTC+02", -2 * 3600)
    for target in [current - initDuration(hours=1), current,
        current + initDuration(hours=1)]:
      let deadline = target.inZone(zone)
      let actual = onceNextRun(deadline, none(DateTime)).get()
      check actual == target
      check actual.nanosecond == 123_456_789
      check actual.timezone == zone
      for previous in [current, deadline]:
        check onceNextRun(deadline, some(previous)).isNone

suite "Nominal bounds and repeatability":
  test "all schedule kinds retain absent and inclusive upper bounds":
    let current = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
    let callback = proc(query: DateTime): Option[DateTime] {.
        gcsafe, raises: []
      .} = some(query + initDuration(microseconds=500))
    let candidates = [
      (intervalNextRun(initTimeInterval(minutes=1), current, some(current), current),
        current + initDuration(minutes=1)),
      (cronNextRun(newCron(hour="13", minute="0"), none(Timezone), current),
        dateTime(2026, mJan, 1, 13, 0, 0, 0, utc())),
      (customNextRun(callback, current, current),
        current + initDuration(microseconds=500)),
      (onceNextRun(current, none(DateTime)), current)
    ]
    for (candidate, target) in candidates:
      require candidate == some(target)
      check withinEndTime(candidate, none(DateTime)) == some(target)
      check withinEndTime(candidate, some(target)) == some(target)
      check withinEndTime(candidate, some(target + initDuration(nanoseconds=1))) ==
        some(target)
      check withinEndTime(candidate, some(target - initDuration(nanoseconds=1))).isNone

  test "upper bounds preserve exhausted and empty candidates":
    let target = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
    for bound in [none(DateTime), some(target)]:
      check withinEndTime(none(DateTime), bound).isNone
      check withinEndTime(onceNextRun(target, some(target)), bound).isNone

  test "built-in calculations repeat with fixed inputs":
    let current = dateTime(2026, mJan, 1, 12, 35, 0, 0, utc())
    let anchor = dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())
    let interval = initTimeInterval(minutes=10)
    let cron = newCron(hour="13", minute="0")
    for previous in [none(DateTime), some(anchor)]:
      let intervalResult = intervalNextRun(interval, anchor, previous, current)
      let onceResult = onceNextRun(anchor, previous)
      for attempt in 1..3:
        check intervalNextRun(interval, anchor, previous, current) == intervalResult
        check onceNextRun(anchor, previous) == onceResult
    for zone in [none(Timezone), some(fixedTimezone("Test/UTC+02", -2 * 3600))]:
      let cronResult = cronNextRun(cron, zone, current)
      for attempt in 1..3:
        check cronNextRun(cron, zone, current) == cronResult
