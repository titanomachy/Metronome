import asyncdispatch, times
import schedules

scheduler oneShotSched:
  at(time=now()+initDuration(milliseconds=50), id="warm-cache", async=true):
    echo "[warm-cache] Running once at: ", now()

proc main() {.async.} =
  echo "Starting one-shot scheduler example..."
  await oneShotSched.start()
  await sleepAsync(100)

if isMainModule:
  waitFor main()
