# Package

version       = "0.3.1"
author        = "titanomachy"
description   = "A Nim scheduler library that lets you kick off jobs at regular intervals."
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.10"

task coverage, "Run tests and generate code coverage report":
  echo "Compiling and running tests with coverage instrumentation..."
  rmDir("nimcache")
  exec "nim c --debugger:native --passC:--coverage --passL:--coverage --nimcache:nimcache/cron -r tests/test_cron.nim"
  exec "nim c --debugger:native --passC:--coverage --passL:--coverage --nimcache:nimcache/scheduler -r tests/test_scheduler.nim"
  exec "nim c --debugger:native --passC:--coverage --passL:--coverage --nimcache:nimcache/beater -r tests/test_beater.nim"
  echo "Tests completed successfully."
  echo "To generate the HTML report and README coverage badge locally, please ensure 'lcov' and 'genhtml' are installed, then run:"
  echo "  ./code_coverage.sh"

task docs, "Generate HTML documentation":
  echo "Generating HTML documentation..."
  rmDir("docs")
  exec "nim doc --project --outDir:docs --threads:on --index:on src/schedules.nim"
