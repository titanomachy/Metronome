import std/[asyncdispatch, options, strutils, times, unittest]

import metronome
import metronome/timers
import metronome/timezones

proc noop(): Future[void] {.async.} =
  discard

proc threadNoop() {.thread.} =
  discard

proc utcDate(
  year: int,
  month: Month,
  day, hour, minute, second: int,
  microsecond = 0
): DateTime =
  dateTime(year, month, day, hour, minute, second, microsecond * 1_000, utc())

scheduler timerDslScheduler:
  timer(
    onCalendar="*-*-* 02:00:00 Europe/Amsterdam",
    id="async-timer",
    async=true
  ):
    discard
  timer(
    onCalendar=["daily UTC", "weekly Europe/Amsterdam"],
    id="thread-timer"
  ):
    discard

suite "systemd-style calendar timers":
  test "evaluates the requested Amsterdam expression":
    let timer = newTimer("*-*-* 02:00:00 Europe/Amsterdam")
    check timer.getNext(utcDate(2026, mJan, 15, 0, 0, 0)).get() ==
      utcDate(2026, mJan, 15, 1, 0, 0)
    check timer.getNext(utcDate(2026, mJul, 15, 0, 0, 0)).get() ==
      utcDate(2026, mJul, 16, 0, 0, 0)

  test "returns a match strictly later than current":
    let timer = newTimer("*-*-* 02:00:00 UTC")
    check timer.getNext(utcDate(2026, mJan, 15, 2, 0, 0)).get() ==
      utcDate(2026, mJan, 16, 2, 0, 0)

  test "supports exact and rounded microseconds":
    let exact = newTimer("*-*-* *:*:00.123456 UTC")
    check exact.getNext(utcDate(2026, mJan, 15, 12, 34, 0)).get() ==
      utcDate(2026, mJan, 15, 12, 34, 0, 123_456)
    check exact.getNext(utcDate(2026, mJan, 15, 12, 34, 0, 123_456)).get() ==
      utcDate(2026, mJan, 15, 12, 35, 0, 123_456)

    let rounded = newTimer("*-*-* *:*:00.0000005 UTC")
    check rounded.getNext(utcDate(2026, mJan, 15, 12, 34, 0)).get() ==
      utcDate(2026, mJan, 15, 12, 34, 0, 1)

    let carried = newTimer("*-*-* *:*:00.9999995 UTC")
    check carried.getNext(utcDate(2026, mJan, 15, 12, 34, 0)).get() ==
      utcDate(2026, mJan, 15, 12, 34, 1)

  test "supports fractional second repetitions without scanning microseconds":
    let timer = newTimer("*-*-* *:*:00/0.5 UTC")
    check timer.getNext(utcDate(2026, mJan, 15, 12, 34, 0, 100_000)).get() ==
      utcDate(2026, mJan, 15, 12, 34, 0, 500_000)
    check timer.getNext(utcDate(2026, mJan, 15, 12, 34, 0, 500_000)).get() ==
      utcDate(2026, mJan, 15, 12, 34, 1)

  test "supports lists ranges and repetitions":
    let timer = newTimer(
      "2026,2028-01..03/2-01,15 01..05/2:02/3:00..02/0.5 UTC"
    )
    check timer.getNext(utcDate(2026, mJan, 1, 1, 2, 0, 100_000)).get() ==
      utcDate(2026, mJan, 1, 1, 2, 0, 500_000)
    check timer.getNext(utcDate(2026, mMar, 15, 5, 59, 59)).get() ==
      utcDate(2028, mJan, 1, 1, 2, 0)

  test "combines weekday and date restrictions with AND semantics":
    let timer = newTimer("Mon..Fri *-*-01 02:00:00 UTC")
    check timer.getNext(utcDate(2026, mJul, 31, 23, 0, 0)).get() ==
      utcDate(2026, mSep, 1, 2, 0, 0)

  test "supports last days and last-weekday idioms":
    let thirdLastFebruary = newTimer("*-02~03 00:00:00 UTC")
    check thirdLastFebruary.getNext(utcDate(2026, mJan, 1, 0, 0, 0)).get() ==
      utcDate(2026, mFeb, 26, 0, 0, 0)
    check thirdLastFebruary.getNext(utcDate(2027, mMar, 1, 0, 0, 0)).get() ==
      utcDate(2028, mFeb, 27, 0, 0, 0)

    let lastMondayInMay = newTimer("Mon *-05~07/1 00:00:00 UTC")
    check lastMondayInMay.getNext(utcDate(2026, mMay, 1, 0, 0, 0)).get() ==
      utcDate(2026, mMay, 25, 0, 0, 0)

  test "supports systemd calendar shorthands":
    check newTimer("minutely UTC").getNext(
      utcDate(2026, mJan, 1, 12, 34, 1)
    ).get() == utcDate(2026, mJan, 1, 12, 35, 0)
    check newTimer("hourly UTC").getNext(
      utcDate(2026, mJan, 1, 12, 34, 1)
    ).get() == utcDate(2026, mJan, 1, 13, 0, 0)
    check newTimer("daily UTC").getNext(
      utcDate(2026, mJan, 1, 12, 0, 0)
    ).get() == utcDate(2026, mJan, 2, 0, 0, 0)
    check newTimer("monthly UTC").getNext(
      utcDate(2026, mJan, 2, 0, 0, 0)
    ).get() == utcDate(2026, mFeb, 1, 0, 0, 0)
    check newTimer("weekly UTC").getNext(
      utcDate(2026, mJan, 1, 0, 0, 0)
    ).get() == utcDate(2026, mJan, 5, 0, 0, 0)
    check newTimer("yearly UTC").getNext(
      utcDate(2026, mJan, 2, 0, 0, 0)
    ).get() == utcDate(2027, mJan, 1, 0, 0, 0)
    check newTimer("annually UTC").getNext(
      utcDate(2026, mJan, 2, 0, 0, 0)
    ).get() == utcDate(2027, mJan, 1, 0, 0, 0)
    check newTimer("quarterly UTC").getNext(
      utcDate(2026, mFeb, 1, 0, 0, 0)
    ).get() == utcDate(2026, mApr, 1, 0, 0, 0)
    check newTimer("semiannually UTC").getNext(
      utcDate(2026, mFeb, 1, 0, 0, 0)
    ).get() == utcDate(2026, mJul, 1, 0, 0, 0)

  test "supports omitted date or time":
    check newTimer("02:00 UTC").getNext(
      utcDate(2026, mJan, 1, 3, 0, 0)
    ).get() == utcDate(2026, mJan, 2, 2, 0, 0)
    check newTimer("2027-01-01 UTC").getNext(
      utcDate(2026, mJan, 1, 0, 0, 0)
    ).get() == utcDate(2027, mJan, 1, 0, 0, 0)

  test "returns none after an exhausted one-time expression":
    let timer = newTimer("2026-01-01 00:00:00 UTC")
    check timer.getNext(utcDate(2026, mJan, 1, 0, 0, 0)).isNone

  test "selects the earliest of repeated OnCalendar expressions":
    let timer = newTimer([
      "*-*-* 12:00:00 UTC",
      "*-*-* 09:00:00 UTC",
      "*-*-* 09:00:00 UTC"
    ])
    check timer.getNext(utcDate(2026, mJan, 1, 8, 0, 0)).get() ==
      utcDate(2026, mJan, 1, 9, 0, 0)

  test "uses the current DateTime timezone when no suffix is present":
    let chicago = namedTimezone("America/Chicago")
    let current = dateTime(2026, mJul, 1, 1, 0, 0, 0, chicago)
    let next = newTimer("*-*-* 02:00:00").getNext(current).get()
    check next.timezone.name == chicago.name
    check next.hour == 2

  test "returns explicit-zone results in the caller timezone":
    let chicago = namedTimezone("America/Chicago")
    let current = utcDate(2026, mJul, 1, 0, 0, 0).inZone(chicago)
    let next = newTimer(
      "*-*-* 09:00:00 Europe/Amsterdam"
    ).getNext(current).get()
    check next.timezone.name == chicago.name
    check next.toTime == utcDate(2026, mJul, 1, 7, 0, 0).toTime

  test "skips nonexistent DST wall times":
    let timer = newTimer("*-*-* 02:30:00 Europe/Amsterdam")
    check timer.getNext(utcDate(2026, mMar, 29, 0, 0, 0)).get() ==
      utcDate(2026, mMar, 30, 0, 30, 0)

  test "jumps over dense schedules in nonexistent DST wall time":
    let timer = newTimer(
      "*-*-* 02,03:*:00/0.000001 Europe/Amsterdam"
    )
    check timer.getNext(utcDate(2026, mMar, 29, 0, 0, 0)).get() ==
      utcDate(2026, mMar, 29, 1, 0, 0)

  test "uses only the earlier occurrence of ambiguous wall times":
    let timer = newTimer("*-*-* 02:30:00 Europe/Amsterdam")
    check timer.getNext(utcDate(2026, mOct, 24, 23, 0, 0)).get() ==
      utcDate(2026, mOct, 25, 0, 30, 0)
    check timer.getNext(utcDate(2026, mOct, 25, 0, 30, 0)).get() ==
      utcDate(2026, mOct, 26, 1, 30, 0)

  test "uses recurring timezone rules after 2037":
    let amsterdam = newTimer("*-*-* 09:00:00 Europe/Amsterdam")
    let chicago = newTimer("*-*-* 09:00:00 America/Chicago")
    check amsterdam.getNext(utcDate(2040, mJul, 1, 0, 0, 0)).get() ==
      utcDate(2040, mJul, 1, 7, 0, 0)
    check chicago.getNext(utcDate(2040, mJul, 1, 0, 0, 0)).get() ==
      utcDate(2040, mJul, 1, 14, 0, 0)

  test "handles extremely large integer repetitions without overflow":
    let timer = newTimer(
      "1/9223372036854775807-01-01 00:00:00 UTC"
    )
    check timer.getNext(utcDate(2026, mJan, 1, 0, 0, 0)).isNone

  test "rejects malformed expressions and invalid values":
    for expression in [
      "",
      "not-a-calendar",
      "*-13-01 00:00:00 UTC",
      "*-*-32 00:00:00 UTC",
      "*-*-* 24:00:00 UTC",
      "*-*-* 00:60:00 UTC",
      "*-*-* 00:00:60 UTC",
      "*-*-* 00:00:00/0 UTC",
      "*-*-* 00:*/2:00 UTC",
      "Fri..Mon *-*-* 00:00:00 UTC",
      "*-*-* 00:00:00 Mars/Olympus"
    ]:
      expect ValueError:
        discard newTimer(expression)

    expect ValueError:
      discard newTimer(newSeq[string]())

    var diagnostic = ""
    try:
      discard newTimer("Funday *-*-* 00:00:00 UTC")
    except ValueError as error:
      diagnostic = error.msg
    check diagnostic.contains("invalid weekday: Funday")

  test "initializes direct timer beaters with start and end bounds":
    let timer = newTimer("*-*-* *:*:00 UTC")
    let start = utcDate(2026, mJan, 1, 12, 1, 0)
    let finish = utcDate(2026, mJan, 1, 12, 2, 0)
    let beater = initTimerBeater(
      timer,
      noop,
      startTime = some(start),
      endTime = some(finish)
    )
    check beater.kind == bkCustom
    check beater.fireTime(none(DateTime), utcDate(2026, mJan, 1, 12, 0, 0)).get() == start
    check beater.fireTime(none(DateTime), finish).isNone

    let threadBeater = initTimerBeater(timer, threadNoop)
    check threadBeater.kind == bkCustom
    threadBeater.pause()
    check threadBeater.state == bsPaused
    threadBeater.resume()
    check threadBeater.state == bsRunning
    threadBeater.stop()
    check threadBeater.state == bsStopped

  test "expands async and thread timer DSL jobs":
    check timerDslScheduler.listJobs() == @["async-timer", "thread-timer"]
