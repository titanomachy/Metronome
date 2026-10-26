# Package

version       = "0.5.3"
author        = "titanomachy"
description   = "Metronome is a library for time-based job scheduling supporting cron jobs, systemd-style timers, interval-based timers, and one-shot tasks."
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.10"

task coverage, "Run tests and generate code coverage report":
  exec "./code_coverage.sh"

task docs, "Generate HTML documentation":
  echo "Generating HTML documentation..."
  for generatedFile in [
    "docs/metronome.html",
    "docs/metronome.idx",
    "docs/timezones.html",
    "docs/timezones.idx",
    "docs/timers.html",
    "docs/timers.idx",
    "docs/schedules.html",
    "docs/schedules.idx",
    "docs/theindex.html",
    "docs/dochack.js",
    "docs/nimdoc.out.css"
  ]:
    if fileExists(generatedFile):
      rmFile(generatedFile)
  for generatedDir in ["docs/metronome", "docs/schedules"]:
    if dirExists(generatedDir):
      rmDir(generatedDir)
  exec "nim doc --project --outDir:docs --threads:on --index:on src/metronome.nim"
  exec "nim doc --outDir:docs --threads:on --index:on src/metronome/timezones.nim"
  exec "nim doc --outDir:docs --threads:on --index:on src/metronome/timers.nim"
  # Keep the implementation page for module import links, but omit its symbols
  # from the supported API index generated below.
  if fileExists("docs/metronome/private/schedule.idx"):
    rmFile("docs/metronome/private/schedule.idx")
  exec "nim buildIndex --out:docs/theindex.html docs"
