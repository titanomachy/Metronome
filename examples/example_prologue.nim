import times, asyncdispatch, metronome, prologue

scheduler mySched:
  every(seconds=1, id="sync tick"):
    echo("sync tick, seconds=1 ", now())

proc hello*(ctx: Context) {.async.} =
  resp "<h1>Hello, Prologue! It's alive!</h1>"

proc main() =
  # Start the scheduler in the background of the async event loop
  asyncCheck mySched.start()

  # Set up and run the Prologue web application
  let settings = prologue.newSettings()
  var app = newApp(settings = settings)
  app.addRoute("/", hello)
  app.run()

if isMainModule:
  main()
