## Compile disposable consumers with the same compiler as the test suite.
## These files live outside tests/, so they need explicit path/thread settings.
import std/[os, osproc, tempfiles]

const
  Compiler = getCurrentCompilerExe()
  SourceDir = currentSourcePath().parentDir.parentDir / "src"

proc checkConsumer*(source: string, dependencies = false): tuple[
  output: string, exitCode: int, dependencies: string
] =
  let directory = createTempDir("metronome-consumer-", "")
  try:
    let consumer = directory / "consumer.nim"
    let cache = directory / "cache"
    writeFile(consumer, source)
    var args = @[
      Compiler, (if dependencies: "c" else: "check"),
      "--skipUserCfg:on", "--skipParentCfg:on", "--skipProjCfg:on",
      "--threads:on", "--hints:off", "--colors:off",
      "--path:" & SourceDir, "--nimcache:" & cache,
      "--out:" & directory / "consumer"
    ]
    if dependencies:
      args.add "--genScript:on"
    args.add consumer
    let checked = execCmdEx(quoteShellCommand(args))
    result.output = checked.output
    result.exitCode = checked.exitCode
    let dependencyFile = cache / "consumer.deps"
    if dependencies and fileExists(dependencyFile):
      result.dependencies = readFile(dependencyFile)
  finally:
    removeDir(directory)
