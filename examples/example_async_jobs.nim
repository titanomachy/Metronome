import asyncdispatch, times
import metronome

scheduler asyncJobs:
  at(time=now() + initDuration(milliseconds=50), id="async-once", async=true):
    echo "[async-once] Started at: ", now()
    await sleepAsync(100)
    echo "[async-once] Finished at: ", now()

  every(seconds=1, id="async-interval", async=true):
    echo "[async-interval] Started at: ", now()
    await sleepAsync(200)
    echo "[async-interval] Finished at: ", now()

proc main() {.async.} =
  echo "Starting async scheduler example..."
  asyncCheck asyncJobs.start()

  # Keep this example's event loop alive long enough to run both jobs.
  await sleepAsync(2200)
  asyncJobs.stopAll()
  await sleepAsync(250)
  echo "Async scheduler example complete."

if isMainModule:
  waitFor main()
