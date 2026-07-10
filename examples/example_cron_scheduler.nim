import times, asyncdispatch
import schedules

# Initialize our custom scheduler
scheduler myCronSched:

  # Run every minute (step syntax)
  cron(minute="*/1", id="every-minute"):
    echo "[every-minute] Tick at: ", now()

  # Run every hour at minute 0 and 30 (list syntax)
  cron(minute="0,30", hour="*", id="half-hourly"):
    echo "[half-hourly] Tick at: ", now()

  # Run on the 3rd Monday of the month at 4:05 AM (indexing syntax `#`)
  cron(minute="5", hour="4", day_of_week="1#3", id="third-monday"):
    echo "[third-monday] Running on the 3rd Monday of the month: ", now()

  # Run on the last Friday of the month at 11:30 PM (last-day-of-week syntax `L`)
  cron(minute="30", hour="23", day_of_week="5L", id="last-friday"):
    echo "[last-friday] Running on the last Friday of the month: ", now()

proc main() =
  echo "Starting advanced cron scheduler example..."
  # Start the scheduler and keep the event loop running.
  myCronSched.serve()

if isMainModule:
  main()
