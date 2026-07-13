# Package

version       = "0.4.2"
author        = "titanomachy"
description   = "Metronome is a Nim library for interval, cron, and one-shot jobs."
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
  exec "nim buildIndex --out:docs/theindex.html docs"
