import std/[asyncdispatch, options, times]

import metronome
import metronome/timezones

proc noop(): Future[void] {.async.} =
  discard

# Change only this name to schedule the same wall-clock hour in another place,
# for example "America/Chicago".
const ScheduledZoneName = "Europe/Amsterdam"
let scheduledZone = namedTimezone(ScheduledZoneName)

let dailyLocal = initBeater(
  newCron(hour = "9", minute = "0"),
  noop,
  id = "local-daily",
  timezone = some(scheduledZone)
)

# The same resolved Timezone can also be passed directly to the scheduler DSL.
scheduler timezoneSched:
  cron(
    hour = "9",
    minute = "0",
    id = "local-daily-macro",
    async = true,
    timezone = scheduledZone
  ):
    echo "Running at 09:00 in ", ScheduledZoneName, ": ", now().inZone(scheduledZone)

proc showNextRun(current: DateTime) =
  let nextRun = dailyLocal.fireTime(none(DateTime), current).get()
  echo "From ", current, " the next run is:"
  echo "  UTC:   ", nextRun
  echo "  Local: ", nextRun.inZone(scheduledZone)

proc main() =
  echo "Embedded IANA database: ", timezoneDatabaseVersion()
  echo "Schedule: 09:00 in ", ScheduledZoneName

  # Amsterdam is UTC+1 in winter and UTC+2 in summer. The UTC launch time
  # changes, while the requested 09:00 local wall-clock hour stays fixed.
  showNextRun(dateTime(2026, mJan, 15, 7, 30, 0, 0, utc()))
  showNextRun(dateTime(2026, mJul, 15, 6, 30, 0, 0, utc()))

  # Start the live scheduler in an application with:
  # timezoneSched.serve()
  discard timezoneSched

when isMainModule:
  main()
