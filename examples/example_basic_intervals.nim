# Compile and run from the repository root:
# nim c --threads:on -r examples/example_basic_intervals.nim
import times, asyncdispatch, os, options
import metronome

# 1. Initialize a custom scheduler
scheduler myBasicSched:

  # Run a sync procedure every 2 seconds
  every(seconds=2, id="sync-task"):
    echo "[sync-task] Running at: ", now()
    # sleep() blocks this worker thread. The default throttle=1 prevents
    # overlapping runs of this job.
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
  # serve() stays alive after the windowed job's schedule is exhausted.
  myBasicSched.serve()

if isMainModule:
  main()
