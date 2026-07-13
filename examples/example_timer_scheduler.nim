import std/[asyncdispatch, options, times]

import metronome
import metronome/timers
import metronome/timezones

proc noop(): Future[void] {.async.} =
  discard

# Change only this name to move the wall-clock schedule, for example to
# "America/Chicago". No manual DST rule is needed.
const ScheduledZoneName = "Europe/Amsterdam"
const OnCalendar = "*-*-* 02:00:00 " & ScheduledZoneName

let calendarTimer = newTimer(OnCalendar)
let scheduledZone = namedTimezone(ScheduledZoneName)

let directTimer = initTimerBeater(
  calendarTimer,
  noop,
  id="nightly-direct"
)

scheduler timerSched:
  timer(onCalendar=OnCalendar, id="nightly", async=true):
    echo "Running at 02:00 in ", ScheduledZoneName

proc showNextRun(current: DateTime) =
  let nextRun = calendarTimer.getNext(current).get()
  echo "From ", current, " the next OnCalendar run is:"
  echo "  UTC:   ", nextRun
  echo "  Local: ", nextRun.inZone(scheduledZone)

proc main() =
  echo "OnCalendar=", OnCalendar
  showNextRun(dateTime(2026, mJan, 15, 0, 0, 0, 0, utc()))
  showNextRun(dateTime(2026, mJul, 15, 23, 0, 0, 0, utc()))

  let precise = newTimer("*-*-* *:*:00.123456 UTC")
  let preciseNext = precise.getNext(
    dateTime(2026, mJan, 15, 12, 34, 0, 0, utc())
  ).get()
  echo "Microsecond calendar target: ", preciseNext,
    " (nanosecond field: ", preciseNext.nanosecond, ")"

  # Start the live scheduler in an application with:
  # timerSched.serve()
  discard timerSched
  discard directTimer

when isMainModule:
  main()
