## Regenerate Metronome's embedded IANA timezone catalog.
##
## Maintainer requirements: curl, sha256sum, tar, make, and a C99 compiler.
## Both tzdata and the zic source are pinned and checksummed; the host's zic is
## deliberately never used.

import std/[algorithm, os, osproc, strutils, tables]

const
  PinnedVersion = "2026c"
  TzdataSha256 = "e4a178a4477f3d0ea77cc31828ff72aa38feff8d61aa13e7e99e142e9d902be4"
  TzcodeSha256 = "b1cffc3ace4c4c7cd0efba2f7add86ec3d0b79da48bcf03582671fd3c8feace8"
  ReleaseBase = "https://data.iana.org/time-zones/releases/"
  CatalogMagic = "MTZDB001"
  SourceFiles = [
    "africa",
    "antarctica",
    "asia",
    "australasia",
    "europe",
    "northamerica",
    "southamerica",
    "etcetera",
    "factory",
    "backward"
  ]
  RepositoryRoot = currentSourcePath.parentDir.parentDir
  DefaultOutput = RepositoryRoot / "src" / "metronome" / "timezones" /
    "data" / (PinnedVersion & ".tzdb")

proc usage() =
  echo "Usage: nim r tools/update_timezones.nim -- VERSION [--check] [--output:PATH]"
  echo "Supported pinned version: " & PinnedVersion

proc requireExecutable(name: string) =
  if findExe(name).len == 0:
    raise newException(IOError, "Required maintainer tool is not installed: " & name)

proc run(command: string, arguments: openArray[string], workingDir = "") =
  let process = startProcess(
    command,
    workingDir = workingDir,
    args = arguments,
    options = {poUsePath, poParentStreams}
  )
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    raise newException(
      OSError,
      command & " failed with exit code " & $exitCode
    )

proc sha256(path: string): string =
  let output = execProcess(
    "sha256sum",
    args = [path],
    options = {poUsePath, poStdErrToStdOut}
  )
  let fields = output.splitWhitespace()
  if fields.len == 0:
    raise newException(IOError, "sha256sum returned no digest for " & path)
  fields[0].toLowerAscii()

proc downloadAndVerify(url, destination, expectedDigest: string) =
  run("curl", ["-fL", "-o", destination, url])
  let actualDigest = sha256(destination)
  if actualDigest != expectedDigest:
    raise newException(
      ValueError,
      "Checksum mismatch for " & destination & ": expected " &
        expectedDigest & ", got " & actualDigest
    )

proc appendUint16(destination: var string, value: int) =
  doAssert value >= 0 and value <= 0xffff
  destination.add char((value shr 8) and 0xff)
  destination.add char(value and 0xff)

proc appendUint32(destination: var string, value: int) =
  doAssert value >= 0 and uint64(value) <= uint64(high(uint32))
  destination.add char((value shr 24) and 0xff)
  destination.add char((value shr 16) and 0xff)
  destination.add char((value shr 8) and 0xff)
  destination.add char(value and 0xff)

proc appendShortString(destination: var string, value: string) =
  doAssert value.len <= 0xff
  destination.add char(value.len)
  destination.add value

proc buildCatalog(zoneDirectory, dataVersion, zicVersion: string): string =
  var names: seq[string]
  for relativePath in walkDirRec(zoneDirectory, relative = true):
    names.add relativePath.replace('\\', '/')
  names.sort(system.cmp[string])

  var blobs: seq[string]
  var blobByContent = initTable[string, int]()
  var blobForName = newSeq[int](names.len)

  for index, name in names:
    let content = readFile(zoneDirectory / name)
    if content in blobByContent:
      blobForName[index] = blobByContent[content]
    else:
      blobForName[index] = blobs.len
      blobByContent[content] = blobs.len
      blobs.add content

  result.add CatalogMagic
  result.appendShortString(dataVersion)
  result.appendShortString(zicVersion)
  result.appendUint32(blobs.len)
  for blob in blobs:
    result.appendUint32(blob.len)
    result.add blob

  result.appendUint32(names.len)
  for index, name in names:
    result.appendUint16(name.len)
    result.add name
    result.appendUint32(blobForName[index])

  echo "Packed " & $names.len & " names and aliases into " &
    $blobs.len & " unique TZif records (" & $result.len & " bytes)."

proc regenerate(version, outputPath: string, checkOnly: bool) =
  if version != PinnedVersion:
    raise newException(
      ValueError,
      "Version " & version & " is not pinned. Update the version and both " &
        "checksums in tools/update_timezones.nim first."
    )

  for tool in ["curl", "sha256sum", "tar", "make", "c99"]:
    requireExecutable(tool)

  let workDirectory = getTempDir() / ("metronome-timezones-" & version)
  let sourceDirectory = workDirectory / "source"
  let zoneDirectory = workDirectory / "zoneinfo"
  if dirExists(workDirectory):
    removeDir(workDirectory)
  createDir(sourceDirectory)
  createDir(zoneDirectory)

  let dataArchive = workDirectory / ("tzdata" & version & ".tar.gz")
  let codeArchive = workDirectory / ("tzcode" & version & ".tar.gz")
  downloadAndVerify(
    ReleaseBase & dataArchive.extractFilename,
    dataArchive,
    TzdataSha256
  )
  downloadAndVerify(
    ReleaseBase & codeArchive.extractFilename,
    codeArchive,
    TzcodeSha256
  )

  run("tar", ["-xzf", dataArchive, "-C", sourceDirectory])
  run("tar", ["-xzf", codeArchive, "-C", sourceDirectory])
  run("make", ["zic"], sourceDirectory)

  let builtZic = sourceDirectory / "zic"
  let builtVersion = execProcess(
    builtZic,
    args = ["--version"],
    options = {poStdErrToStdOut}
  ).strip()
  if not builtVersion.endsWith(" " & version):
    raise newException(
      ValueError,
      "Pinned zic reported an unexpected version: " & builtVersion
    )

  var zicArguments = @["-b", "fat", "-d", zoneDirectory]
  for sourceFile in SourceFiles:
    zicArguments.add sourceFile
  run(builtZic, zicArguments, sourceDirectory)

  let generated = buildCatalog(zoneDirectory, version, version)
  if checkOnly:
    if not fileExists(outputPath):
      raise newException(IOError, "Timezone catalog does not exist: " & outputPath)
    if readFile(outputPath) != generated:
      raise newException(ValueError, "Timezone catalog is not up to date")
    echo "Timezone catalog is deterministic and up to date: " & outputPath
  else:
    createDir(outputPath.parentDir)
    writeFile(outputPath, generated)
    echo "Wrote " & outputPath

when isMainModule:
  var version = ""
  var outputPath = DefaultOutput
  var checkOnly = false

  for argument in commandLineParams():
    if argument == "--":
      discard
    elif argument == "--check":
      checkOnly = true
    elif argument.startsWith("--output:"):
      outputPath = argument["--output:".len .. ^1]
    elif argument.startsWith("-"):
      usage()
      quit("Unknown option: " & argument, QuitFailure)
    elif version.len == 0:
      version = argument
    else:
      usage()
      quit("Only one VERSION may be supplied", QuitFailure)

  if version.len == 0:
    usage()
    quit(QuitFailure)

  try:
    regenerate(version, outputPath, checkOnly)
  except CatchableError as error:
    quit(error.msg, QuitFailure)
