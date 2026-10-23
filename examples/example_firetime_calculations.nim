# Compile and run from the repository root:
# nim c --threads:on -r examples/example_firetime_calculations.nim
# Fixed UTC inputs and zero jitter keep these previews deterministic.
import asyncdispatch, options, times
import metronome

# Constructors require a job, but fireTime never invokes it or starts an event loop.
proc noop(): Future[void] {.async.} =
  discard

let current = dateTime(2026, mJan, 1, 12, 35, 0, 0, utc())

let intervalBeater = initBeater(
  initTimeInterval(minutes=10),
  noop,
  startTime=some(dateTime(2026, mJan, 1, 12, 0, 0, 0, utc()))
)

# endTime is inclusive, so the candidate exactly at 12:40 remains valid.
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

# No previous nominal occurrence means initial alignment for the intervals.
# These previews do not publish a pending runtime nextRun deadline.
echo "Interval next run: ", intervalBeater.fireTime(none(DateTime), current).get()
echo "Windowed next run: ", windowedBeater.fireTime(none(DateTime), current).get()
echo "Cron next run: ", cronBeater.fireTime(none(DateTime), current).get()
