## TZif parsing and ``times.Timezone`` adaptation.
##
## This module reads the RFC 9636 representation emitted by the pinned IANA
## ``zic`` compiler. Leap-second records are skipped because Metronome embeds
## the ordinary POSIX database rather than the separate ``right`` database.

import std/[options, times]

import ./posixrule

type
  ZoneType = object
    utcOffset: int
    isDst: bool

  ExplicitTransition = object
    atUnix: int64
    typeIndex: int

  ZoneData = ref object
    zoneTypes: seq[ZoneType]
    transitions: seq[ExplicitTransition]
    futureRule: Option[PosixRule]
    offsets: seq[int]

  Header = object
    version: char
    isUtCount: int
    isStdCount: int
    leapCount: int
    transitionCount: int
    typeCount: int
    abbreviationCount: int

  Cursor = object
    content: string
    position: int

const
  HeaderSize = 44
  MaximumReasonableCount = 1_000_000

proc fail(cursor: Cursor, message: string) {.noreturn.} =
  raise newException(
    ValueError,
    "Invalid TZif data at byte " & $cursor.position & ": " & message
  )

proc remaining(cursor: Cursor): int {.inline.} =
  cursor.content.len - cursor.position

proc require(cursor: Cursor, count: int) =
  if count < 0 or cursor.remaining < count:
    cursor.fail("unexpected end of data")

proc readByte(cursor: var Cursor): uint8 =
  cursor.require(1)
  result = uint8(ord(cursor.content[cursor.position]))
  inc cursor.position

proc readUint32(cursor: var Cursor): uint32 =
  cursor.require(4)
  for _ in 0..<4:
    result = (result shl 8) or uint32(cursor.readByte())

proc readInt32(cursor: var Cursor): int32 =
  cast[int32](cursor.readUint32())

proc readInt64(cursor: var Cursor): int64 =
  cursor.require(8)
  var value: uint64
  for _ in 0..<8:
    value = (value shl 8) or uint64(cursor.readByte())
  result = cast[int64](value)

proc skip(cursor: var Cursor, count: int) =
  cursor.require(count)
  cursor.position += count

proc checkedCount(cursor: Cursor, value: uint32, description: string): int =
  if value > uint32(MaximumReasonableCount):
    cursor.fail(description & " is unreasonably large")
  int(value)

proc readHeader(cursor: var Cursor): Header =
  cursor.require(HeaderSize)
  if cursor.content[cursor.position ..< cursor.position + 4] != "TZif":
    cursor.fail("missing TZif magic")
  cursor.position += 4

  result.version = char(cursor.readByte())
  if result.version notin {'\0', '2', '3', '4'}:
    cursor.fail("unsupported TZif version")

  for _ in 0..<15:
    if cursor.readByte() != 0:
      cursor.fail("reserved header bytes must be zero")

  result.isUtCount = cursor.checkedCount(cursor.readUint32(), "UT indicator count")
  result.isStdCount = cursor.checkedCount(
    cursor.readUint32(),
    "standard-time indicator count"
  )
  result.leapCount = cursor.checkedCount(cursor.readUint32(), "leap count")
  result.transitionCount = cursor.checkedCount(
    cursor.readUint32(),
    "transition count"
  )
  result.typeCount = cursor.checkedCount(cursor.readUint32(), "type count")
  result.abbreviationCount = cursor.checkedCount(
    cursor.readUint32(),
    "abbreviation count"
  )

  if result.typeCount == 0 or result.typeCount > 256:
    cursor.fail("type count must be between 1 and 256")
  if result.isUtCount notin [0, result.typeCount]:
    cursor.fail("UT indicator count must be zero or equal the type count")
  if result.isStdCount notin [0, result.typeCount]:
    cursor.fail("standard indicator count must be zero or equal the type count")

proc blockSize(cursor: Cursor, header: Header, timeSize: int): int =
  let size = int64(header.transitionCount) * int64(timeSize) +
    int64(header.transitionCount) + int64(header.typeCount) * 6'i64 +
    int64(header.abbreviationCount) +
    int64(header.leapCount) * int64(timeSize + 4) +
    int64(header.isStdCount) + int64(header.isUtCount)
  if size > int64(high(int)):
    cursor.fail("data block is too large")
  int(size)

proc skipBlock(cursor: var Cursor, header: Header, timeSize: int) =
  cursor.skip(cursor.blockSize(header, timeSize))

proc parseBlock(cursor: var Cursor, header: Header, timeSize: int): ZoneData =
  var transitionTimes = newSeq[int64](header.transitionCount)
  for index in 0..<transitionTimes.len:
    transitionTimes[index] =
      if timeSize == 8:
        cursor.readInt64()
      else:
        int64(cursor.readInt32())

  var transitionTypes = newSeq[int](header.transitionCount)
  for index in 0..<transitionTypes.len:
    transitionTypes[index] = int(cursor.readByte())
    if transitionTypes[index] >= header.typeCount:
      cursor.fail("transition references an unknown local-time type")

  result = ZoneData(zoneTypes: newSeq[ZoneType](header.typeCount))
  for index in 0..<result.zoneTypes.len:
    let secondsEast = cursor.readInt32()
    let daylight = cursor.readByte()
    discard cursor.readByte() # abbreviation index
    if secondsEast == low(int32):
      cursor.fail("invalid UTC offset")
    if daylight > 1:
      cursor.fail("DST marker must be zero or one")
    result.zoneTypes[index] = ZoneType(
      utcOffset: -int(secondsEast),
      isDst: daylight == 1
    )

  cursor.skip(header.abbreviationCount)
  cursor.skip(header.leapCount * (timeSize + 4))
  cursor.skip(header.isStdCount)
  cursor.skip(header.isUtCount)

  result.transitions = newSeq[ExplicitTransition](header.transitionCount)
  for index in 0..<result.transitions.len:
    if index > 0 and transitionTimes[index] <= transitionTimes[index - 1]:
      cursor.fail("transition times must be strictly increasing")
    result.transitions[index] = ExplicitTransition(
      atUnix: transitionTimes[index],
      typeIndex: transitionTypes[index]
    )

proc parseFooter(cursor: var Cursor): Option[PosixRule] =
  if cursor.remaining == 0:
    return none(PosixRule)
  if cursor.readByte() != uint8(ord('\n')):
    cursor.fail("TZif footer must begin with a newline")

  let start = cursor.position
  while cursor.remaining > 0 and cursor.content[cursor.position] != '\n':
    inc cursor.position
  if cursor.remaining == 0:
    cursor.fail("unterminated TZif footer")

  let footer = cursor.content[start ..< cursor.position]
  inc cursor.position
  if cursor.remaining != 0:
    cursor.fail("unexpected bytes after TZif footer")
  if footer.len == 0:
    none(PosixRule)
  else:
    some(parsePosixRule(footer))

proc addOffset(zone: ZoneData, offset: int) =
  for existing in zone.offsets:
    if existing == offset:
      return
  zone.offsets.add offset

proc parseTzif(content: string): ZoneData {.raises: [ValueError].} =
  var cursor = Cursor(content: content)
  let firstHeader = cursor.readHeader()

  if firstHeader.version == '\0':
    result = cursor.parseBlock(firstHeader, 4)
  else:
    cursor.skipBlock(firstHeader, 4)
    let secondHeader = cursor.readHeader()
    if secondHeader.version notin {'2', '3', '4'}:
      cursor.fail("second TZif header has an unsupported version")
    result = cursor.parseBlock(secondHeader, 8)
    result.futureRule = cursor.parseFooter()

  for zoneType in result.zoneTypes:
    result.addOffset(zoneType.utcOffset)
  if result.futureRule.isSome:
    result.addOffset(result.futureRule.get.standardOffset)
    if result.futureRule.get.hasDaylight:
      result.addOffset(result.futureRule.get.daylightOffset)

proc explicitTypeAt(zone: ZoneData, unixTime: int64): ZoneType {.raises: [].} =
  if zone.transitions.len == 0 or unixTime < zone.transitions[0].atUnix:
    return zone.zoneTypes[0]

  var low = 0
  var high = zone.transitions.high
  while low < high:
    let middle = low + (high - low + 1) div 2
    if zone.transitions[middle].atUnix <= unixTime:
      low = middle
    else:
      high = middle - 1
  zone.zoneTypes[zone.transitions[low].typeIndex]

proc infoAt(zone: ZoneData, unixTime: int64): ZoneType {.raises: [].} =
  if zone.futureRule.isSome and
      (zone.transitions.len == 0 or unixTime >= zone.transitions[^1].atUnix):
    let future = posixInfoAt(zone.futureRule.get, unixTime)
    return ZoneType(utcOffset: future.utcOffset, isDst: future.isDst)
  zone.explicitTypeAt(unixTime)

proc explicitGapCandidate(zone: ZoneData, adjustedUnix: int64): Option[int64] =
  for index, transition in zone.transitions:
    let oldType =
      if index == 0:
        zone.zoneTypes[0]
      else:
        zone.zoneTypes[zone.transitions[index - 1].typeIndex]
    let newType = zone.zoneTypes[transition.typeIndex]
    if newType.utcOffset >= oldType.utcOffset:
      continue
    let localBefore = transition.atUnix - int64(oldType.utcOffset)
    let localAfter = transition.atUnix - int64(newType.utcOffset)
    if adjustedUnix >= localBefore and adjustedUnix < localAfter:
      return some(adjustedUnix + int64(oldType.utcOffset))
  none(int64)

proc futureGapCandidate(zone: ZoneData, adjustedUnix: int64): Option[int64] =
  if zone.futureRule.isNone or not zone.futureRule.get.hasDaylight:
    return none(int64)

  let year = fromUnix(adjustedUnix).utc.year
  for candidateYear in year - 1 .. year + 1:
    for transition in zone.futureRule.get.futureTransitions(candidateYear):
      if transition.newOffset >= transition.oldOffset:
        continue
      let localBefore = transition.atUnix - int64(transition.oldOffset)
      let localAfter = transition.atUnix - int64(transition.newOffset)
      if adjustedUnix >= localBefore and adjustedUnix < localAfter:
        return some(adjustedUnix + int64(transition.oldOffset))
  none(int64)

proc newTimezoneFromTzif*(
  name: string,
  content: string
): Timezone {.raises: [ValueError].} =
  ## Construct a standard-library timezone from one embedded TZif record.
  let zone = parseTzif(content)

  proc zoneInfoFromTime(time: Time): ZonedTime
      {.gcsafe, raises: [], tags: [].} =
    let info = zone.infoAt(time.toUnix)
    ZonedTime(time: time, utcOffset: info.utcOffset, isDst: info.isDst)

  proc zoneInfoFromAdjustedTime(adjustedTime: Time): ZonedTime
      {.gcsafe, raises: [], tags: [].} =
    var found = false
    var selected: Time
    var selectedInfo: ZoneType

    for offset in zone.offsets:
      let candidate = adjustedTime + initDuration(seconds = offset)
      let info = zone.infoAt(candidate.toUnix)
      if info.utcOffset == offset and (not found or candidate < selected):
        found = true
        selected = candidate
        selectedInfo = info

    if not found:
      var normalized = zone.explicitGapCandidate(adjustedTime.toUnix)
      if normalized.isNone:
        normalized = zone.futureGapCandidate(adjustedTime.toUnix)
      if normalized.isSome:
        selected = initTime(normalized.get, adjustedTime.nanosecond)
        selectedInfo = zone.infoAt(selected.toUnix)
        found = true

    if not found:
      selectedInfo = zone.infoAt(adjustedTime.toUnix)
      selected = adjustedTime + initDuration(seconds = selectedInfo.utcOffset)

    ZonedTime(
      time: selected,
      utcOffset: selectedInfo.utcOffset,
      isDst: selectedInfo.isDst
    )

  result = newTimezone(name, zoneInfoFromTime, zoneInfoFromAdjustedTime)
