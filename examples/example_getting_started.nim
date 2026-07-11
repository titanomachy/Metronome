import asyncdispatch, times
import metronome

metronome:
  every(seconds=10, id="tick"):
    echo("tick", now())

  every(seconds=10, id="atick", async=true):
    echo("tick", now())
    await sleepAsync(3000)
