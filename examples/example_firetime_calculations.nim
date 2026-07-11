import asyncdispatch, options, times
import metronome

proc noop(): Future[void] {.async.} =
  discard

let current = dateTime(2026, mJan, 1, 12, 35, 0, 0, utc())

let intervalBeater = initBeater(
  initTimeInterval(minutes=10),
  noop,
  startTime=some(dateTime(2026, mJan, 1, 12, 0, 0, 0, utc()))
)

let windowedBeater = initBeater(
  initTimeInterval(minutes=10),
  noop,
  startTime=some(dateTime(2026, mJan, 1, 12, 0, 0, 0, utc())),
  endTime=some(dateTime(2026, mJan, 1, 12, 40, 0, 0, utc()))
)

let cronBeater = initBeater(
  newCron(minute="0", hour="0", day_of_month="1", month="1", year="2027"),
  noop
)

echo "Interval next run: ", intervalBeater.fireTime(none(DateTime), current).get()
echo "Windowed next run: ", windowedBeater.fireTime(none(DateTime), current).get()
echo "Cron next run: ", cronBeater.fireTime(none(DateTime), current).get()
