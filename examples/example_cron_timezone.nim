import asyncdispatch, options, times
import metronome

proc noop(): Future[void] {.async.} =
  discard

let current = now().utc()
let dailyUtc = initBeater(
  newCron(hour="9", minute="0"),
  noop,
  id="utc-daily",
  timezone=some(utc())
)

echo "Current UTC time: ", current
echo "Next 09:00 UTC run: ", dailyUtc.fireTime(none(DateTime), current).get()

scheduler timezoneSched:
  cron(hour="9", minute="0", id="utc-daily-macro", async=true, timezone=utc()):
    echo "[utc-daily-macro] Running at: ", now()

proc main() =
  echo "Starting UTC cron scheduler example..."
  timezoneSched.serve()

if isMainModule:
  main()
