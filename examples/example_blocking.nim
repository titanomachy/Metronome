import os, times, asyncdispatch
import metronome

metronome:
  cron(minute="*/1", id="cron - sync tick"):
    echo("(cron) sync tick, every minute ", now())
    sleep(3000)

  cron(minute="*/1", id="cron - async tick", async=true):
    echo("(cron) async tick, every minute ", now())
    await sleepAsync(3000)

  every(seconds=1, id="sync sleep", throttle=2):
    echo("(interval) sync sleep, seconds=1 ", now())
    sleep(3000)

  every(seconds=2, id="async sleep", async=true, throttle=2):
    echo("(interval) async sleep, seconds=2 ", now())
    await sleepAsync(4000)
