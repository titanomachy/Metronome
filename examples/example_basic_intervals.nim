import times, asyncdispatch, os, options
import schedules

# 1. Initialize a custom scheduler
scheduler myBasicSched:

  # Run a sync procedure every 2 seconds
  every(seconds=2, id="sync-task"):
    echo "[sync-task] Running at: ", now()
    # Note: blocking calls like sleep() will block the current worker thread,
    # so we set throttle=2 to allow multiple runs to overlapping.
    sleep(1000)

  # Run an async procedure every 3 seconds with throttling
  every(seconds=3, id="async-task", async=true, throttle=3):
    echo "[async-task] Started at: ", now()
    await sleepAsync(4000)
    echo "[async-task] Finished at: ", now()

  # Run a task inside a designated time window
  every(
    seconds=1,
    id="windowed-task",
    startTime=now() + initDuration(seconds=2),
    endTime=now() + initDuration(seconds=8)
  ):
    echo "[windowed-task] Running in time range: ", now()

proc main() =
  echo "Starting basic interval scheduler example..."
  # Start the scheduler and keep the event loop running.
  myBasicSched.serve()

if isMainModule:
  main()
