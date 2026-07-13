## POSIX TZ footer parsing and future-transition evaluation.
##
## This is an internal implementation module. TZif version 2 and later use a
## POSIX-style footer to describe recurring changes after their final explicit
## transition.

import std/times

type
  PosixDayKind* = enum
    pdkJulianNoLeap,
    pdkJulianZero,
    pdkMonthWeekDay

  PosixDayRule* = object
    case kind*: PosixDayKind
    of pdkJulianNoLeap:
      julianDay*: int
    of pdkJulianZero:
      zeroDay*: int
    of pdkMonthWeekDay:
      month*: int
      week*: int
      weekday*: int

  PosixTransitionRule* = object
    day*: PosixDayRule
    seconds*: int

  PosixRule* = object
    standardOffset*: int
    hasDaylight*: bool
    daylightOffset*: int
    daylightStart*: PosixTransitionRule
    daylightEnd*: PosixTransitionRule

  FutureTransition* = object
    atUnix*: int64
    oldOffset*: int
    newOffset*: int
    isDst*: bool

  Parser = object
    text: string
    position: int

proc fail(parser: Parser, message: string) {.noreturn.} =
  raise newException(
    ValueError,
    "Invalid POSIX timezone rule at byte " & $parser.position & ": " & message
  )

proc atEnd(parser: Parser): bool {.inline.} =
  parser.position >= parser.text.len

proc current(parser: Parser): char {.inline.} =
  if parser.atEnd:
    '\0'
  else:
    parser.text[parser.position]

proc consume(parser: var Parser, expected: char) =
  if parser.current != expected:
    parser.fail("expected '" & $expected & "'")
  inc parser.position

proc parseNumber(parser: var Parser): int =
  let start = parser.position
  while parser.current in {'0'..'9'}:
    if result > 1_000_000:
      parser.fail("number is too large")
    result = result * 10 + ord(parser.current) - ord('0')
    inc parser.position
  if parser.position == start:
    parser.fail("expected a number")

proc parseName(parser: var Parser) =
  if parser.current == '<':
    inc parser.position
    let start = parser.position
    while not parser.atEnd and parser.current != '>':
      if parser.current in {'\0', '\n'}:
        parser.fail("invalid quoted abbreviation")
      inc parser.position
    if parser.position == start or parser.atEnd:
      parser.fail("unterminated or empty quoted abbreviation")
    inc parser.position
    return

  let start = parser.position
  while parser.current in {'A'..'Z', 'a'..'z'}:
    inc parser.position
  if parser.position - start < 3:
    parser.fail("abbreviations must contain at least three letters")

proc parseClock(parser: var Parser, maxHours: int): int =
  var sign = 1
  if parser.current == '-':
    sign = -1
    inc parser.position
  elif parser.current == '+':
    inc parser.position

  let hours = parser.parseNumber()
  if hours > maxHours:
    parser.fail("hour is outside the supported range")

  var minutes = 0
  var seconds = 0
  if parser.current == ':':
    inc parser.position
    minutes = parser.parseNumber()
    if minutes > 59:
      parser.fail("minutes must be between 0 and 59")
    if parser.current == ':':
      inc parser.position
      seconds = parser.parseNumber()
      if seconds > 59:
        parser.fail("seconds must be between 0 and 59")

  result = sign * (hours * 3600 + minutes * 60 + seconds)

proc parseDayRule(parser: var Parser): PosixDayRule =
  case parser.current
  of 'J':
    inc parser.position
    let day = parser.parseNumber()
    if day notin 1..365:
      parser.fail("Julian day must be between 1 and 365")
    result = PosixDayRule(kind: pdkJulianNoLeap, julianDay: day)
  of 'M':
    inc parser.position
    let month = parser.parseNumber()
    parser.consume('.')
    let week = parser.parseNumber()
    parser.consume('.')
    let weekday = parser.parseNumber()
    if month notin 1..12:
      parser.fail("month must be between 1 and 12")
    if week notin 1..5:
      parser.fail("week must be between 1 and 5")
    if weekday notin 0..6:
      parser.fail("weekday must be between 0 and 6")
    result = PosixDayRule(
      kind: pdkMonthWeekDay,
      month: month,
      week: week,
      weekday: weekday
    )
  of '0'..'9':
    let day = parser.parseNumber()
    if day notin 0..365:
      parser.fail("zero-based Julian day must be between 0 and 365")
    result = PosixDayRule(kind: pdkJulianZero, zeroDay: day)
  else:
    parser.fail("expected a transition date")

proc parseTransition(parser: var Parser): PosixTransitionRule =
  result.day = parser.parseDayRule()
  result.seconds = 2 * 60 * 60
  if parser.current == '/':
    inc parser.position
    result.seconds = parser.parseClock(167)

proc parsePosixRule*(text: string): PosixRule {.raises: [ValueError].} =
  ## Parse the expanded POSIX ``TZ`` syntax used in a TZif footer.
  ##
  ## Offsets use the same convention as ``times.ZonedTime.utcOffset``:
  ## positive values are west of UTC. Transition clocks accept the TZif v3
  ## extension from -167 through 167 hours.
  if text.len == 0:
    raise newException(ValueError, "POSIX timezone rule cannot be empty")

  var parser = Parser(text: text)
  parser.parseName()
  result.standardOffset = parser.parseClock(167)

  if parser.atEnd:
    result.daylightOffset = result.standardOffset
    return

  parser.parseName()
  result.hasDaylight = true
  result.daylightOffset = result.standardOffset - 3600

  if parser.current != ',':
    result.daylightOffset = parser.parseClock(167)

  parser.consume(',')
  result.daylightStart = parser.parseTransition()
  parser.consume(',')
  result.daylightEnd = parser.parseTransition()

  if not parser.atEnd:
    parser.fail("unexpected trailing text")

proc dayOffset*(rule: PosixDayRule, year: int): int =
  ## Return the rule's zero-based day within ``year``.
  case rule.kind
  of pdkJulianNoLeap:
    result = rule.julianDay - 1
    if isLeapYear(year) and rule.julianDay >= 60:
      inc result
  of pdkJulianZero:
    result = rule.zeroDay
  of pdkMonthWeekDay:
    let month = Month(rule.month)
    let firstWeekday = (ord(getDayOfWeek(1, month, year)) + 1) mod 7
    result = 1 + (rule.weekday - firstWeekday + 7) mod 7
    result += (rule.week - 1) * 7
    if result > getDaysInMonth(month, year):
      result -= 7
    result = getDayOfYear(result, month, year)

proc transitionUnix(
  rule: PosixTransitionRule,
  year: int,
  offsetBefore: int
): int64 =
  let yearStart = dateTime(year, mJan, 1, zone = utc()).toTime.toUnix
  result = yearStart + int64(rule.day.dayOffset(year)) * 86_400'i64 +
    int64(rule.seconds) + int64(offsetBefore)

proc futureTransitions*(rule: PosixRule, year: int): array[2, FutureTransition] =
  ## Calculate the two recurring transitions associated with ``year``.
  result[0] = FutureTransition(
    atUnix: rule.daylightStart.transitionUnix(year, rule.standardOffset),
    oldOffset: rule.standardOffset,
    newOffset: rule.daylightOffset,
    isDst: true
  )
  result[1] = FutureTransition(
    atUnix: rule.daylightEnd.transitionUnix(year, rule.daylightOffset),
    oldOffset: rule.daylightOffset,
    newOffset: rule.standardOffset,
    isDst: false
  )

proc isAllYearDaylight(rule: PosixRule): bool =
  if not rule.hasDaylight or rule.daylightOffset <= rule.standardOffset:
    return false
  let current = rule.futureTransitions(2001)
  let previous = rule.futureTransitions(2000)
  current[0].atUnix == previous[1].atUnix

proc posixInfoAt*(
  rule: PosixRule,
  unixTime: int64
): tuple[utcOffset: int, isDst: bool] {.raises: [].} =
  ## Return the recurring offset and DST state at ``unixTime``.
  if not rule.hasDaylight:
    return (rule.standardOffset, false)
  if rule.isAllYearDaylight:
    return (rule.daylightOffset, true)

  let year = fromUnix(unixTime).utc.year
  var found = false
  var latest = low(int64)
  var latestIsDst = false

  for candidateYear in year - 1 .. year + 1:
    for transition in rule.futureTransitions(candidateYear):
      if transition.atUnix <= unixTime and
          (not found or transition.atUnix > latest):
        found = true
        latest = transition.atUnix
        latestIsDst = transition.isDst

  if found and latestIsDst:
    (rule.daylightOffset, true)
  else:
    (rule.standardOffset, false)
