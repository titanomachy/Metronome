# Package

version       = "0.3.1"
author        = "titanomachy"
description   = "A Nim scheduler library that lets you kick off jobs at regular intervals."
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.10"

task coverage, "Run tests and generate code coverage report":
  exec "./code_coverage.sh"

task docs, "Generate HTML documentation":
  echo "Generating HTML documentation..."
  rmDir("docs")
  exec "nim doc --project --outDir:docs --threads:on --index:on src/schedules.nim"
