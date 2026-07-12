import std/[asyncdispatch, logging, times]
import metronome, prologue

let fileLogger = newFileLogger("messages.log", mode=fmAppend)

scheduler mySched:
  every(seconds=1, id="tick", async=true):
    let tickTime = now()
    echo("tick, seconds=1 ", tickTime)
    fileLogger.log(lvlInfo, "1 second tick: ", tickTime)

proc hello*(ctx: Context) {.async.} =
  resp "<h1>Hello, Prologue! It's alive!</h1>"

proc main() {.async.} =
  # Start the scheduler in the background of the async event loop
  asyncCheck mySched.start()

  # Keep Prologue and Metronome on the same async dispatcher. The default
  # blocking app.run() uses HTTPX worker threads and does not poll this loop.
  let settings = prologue.newSettings()
  var app = newApp(settings = settings)
  app.addRoute("/", hello)
  await app.runAsync()

if isMainModule:
  waitFor main()
