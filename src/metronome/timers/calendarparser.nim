## Parser for systemd-style calendar expressions.

import std/[options, strutils, times]

import ../timezones
import ./calendar

type
  FieldValueParser = proc (
    expression, value, fieldName: string
  ): int64 {.nimcall.}

  DateFields = object
    years: ValueMatcher
    months: ValueMatcher
    monthDays: MonthDayRule

  TimeFields = object
    hours: ValueMatcher
    minutes: ValueMatcher
    secondMicros: ValueMatcher

proc calendarError(expression, message: string): ref ValueError =
  newException(
    ValueError,
    "Invalid OnCalendar expression `" & expression & "`: " & message
  )

proc parseUnsigned(expression, value, fieldName: string): int64 =
  if value.len == 0:
    raise calendarError(expression, fieldName & " cannot be empty")
  for character in value:
    if character notin {'0'..'9'}:
      raise calendarError(expression, "invalid " & fieldName & ": " & value)
  try:
    result = parseBiggestInt(value)
  except ValueError:
    raise calendarError(expression, fieldName & " is too large: " & value)

proc parseSecondMicros(
  expression, value, fieldName: string
): int64 =
  let pieces = value.split('.')
  if pieces.len > 2:
    raise calendarError(expression, "invalid " & fieldName & ": " & value)

  var whole = parseUnsigned(expression, pieces[0], fieldName)
  var fraction = 0'i64
  if pieces.len == 2:
    if pieces[1].len == 0:
      raise calendarError(expression, "invalid " & fieldName & ": " & value)
    for character in pieces[1]:
      if character notin {'0'..'9'}:
        raise calendarError(expression, "invalid " & fieldName & ": " & value)

    let retained = min(pieces[1].len, 6)
    for index in 0 ..< retained:
      fraction = fraction * 10 + int64(ord(pieces[1][index]) - ord('0'))
    for _ in retained ..< 6:
      fraction *= 10
    if pieces[1].len > 6 and pieces[1][6] >= '5':
      fraction.inc
      if fraction == MicrosPerSecond:
        whole.inc
        fraction = 0

  if whole > high(int64) div MicrosPerSecond:
    raise calendarError(expression, fieldName & " is too large: " & value)
  result = whole * MicrosPerSecond + fraction

proc splitOnce(
  expression, value, separator, fieldName: string
): tuple[left, right: string] =
  let position = value.find(separator)
  if position < 0 or value.find(separator, position + separator.len) >= 0:
    raise calendarError(expression, "invalid " & fieldName & ": " & value)
  result = (
    value[0 ..< position],
    value[position + separator.len .. ^1]
  )

proc parseMatcher(
  expression, value, fieldName: string,
  minimum, maximum, defaultStep: int64,
  parseValue: FieldValueParser
): ValueMatcher =
  if value.len == 0:
    raise calendarError(expression, fieldName & " cannot be empty")

  for item in value.split(','):
    if item.len == 0:
      raise calendarError(expression, "empty item in " & fieldName)

    let slash = item.find('/')
    if slash >= 0 and item.find('/', slash + 1) >= 0:
      raise calendarError(expression, "invalid repetition in " & fieldName)
    let base = if slash >= 0: item[0 ..< slash] else: item
    let repetition = if slash >= 0: item[slash + 1 .. ^1] else: ""
    if base == "*" and slash >= 0:
      raise calendarError(
        expression,
        "systemd repetitions require an explicit start value in " & fieldName
      )

    var first, last: int64
    if base == "*":
      first = minimum
      last = maximum
    elif ".." in base:
      let bounds = splitOnce(expression, base, "..", fieldName)
      first = parseValue(expression, bounds.left, fieldName)
      last = parseValue(expression, bounds.right, fieldName)
    else:
      first = parseValue(expression, base, fieldName)
      last = if slash >= 0: maximum else: first

    if first < minimum or first > maximum or last < minimum or last > maximum:
      raise calendarError(expression, fieldName & " is outside its valid range")
    if first > last:
      raise calendarError(expression, fieldName & " range must be ascending")

    let step = if slash >= 0:
      if repetition.len == 0:
        raise calendarError(expression, "missing repetition in " & fieldName)
      parseValue(expression, repetition, fieldName & " repetition")
    else:
      defaultStep
    if step <= 0:
      raise calendarError(expression, fieldName & " repetition must be positive")
    result.spans.add ValueSpan(first: first, last: last, step: step)

proc parseIntegerMatcher(
  expression, value, fieldName: string,
  minimum, maximum: int64
): ValueMatcher =
  parseMatcher(
    expression, value, fieldName, minimum, maximum, 1, parseUnsigned
  )

proc parseSecondMatcher(
  expression, value, fieldName: string
): ValueMatcher =
  parseMatcher(
    expression,
    value,
    fieldName,
    0,
    MicrosPerMinute - 1,
    MicrosPerSecond,
    parseSecondMicros
  )

proc weekdayNumber(expression, value: string): int64 =
  case value.toLowerAscii()
  of "mon", "monday": 1
  of "tue", "tuesday": 2
  of "wed", "wednesday": 3
  of "thu", "thursday": 4
  of "fri", "friday": 5
  of "sat", "saturday": 6
  of "sun", "sunday": 7
  else:
    raise calendarError(expression, "invalid weekday: " & value)

proc isWeekdayName(value: string): bool =
  value.toLowerAscii() in [
    "mon", "monday", "tue", "tuesday", "wed", "wednesday",
    "thu", "thursday", "fri", "friday", "sat", "saturday",
    "sun", "sunday"
  ]

proc isWeekdayExpression(value: string): bool =
  if value.len == 0:
    return false
  for item in value.split(','):
    if item.len == 0 or '/' in item:
      return false
    if ".." in item:
      let bounds = item.split("..")
      if bounds.len != 2 or not bounds[0].isWeekdayName or
          not bounds[1].isWeekdayName:
        return false
    elif not item.isWeekdayName:
      return false
  true

proc parseWeekdays(expression, value: string): ValueMatcher =
  for item in value.split(','):
    if item.len == 0 or '/' in item:
      raise calendarError(expression, "invalid weekday list: " & value)
    if ".." in item:
      let bounds = splitOnce(expression, item, "..", "weekday range")
      let first = weekdayNumber(expression, bounds.left)
      let last = weekdayNumber(expression, bounds.right)
      if first > last:
        raise calendarError(expression, "weekday range must be ascending")
      result.spans.add ValueSpan(first: first, last: last, step: 1)
    else:
      let weekday = weekdayNumber(expression, item)
      result.spans.add ValueSpan(first: weekday, last: weekday, step: 1)

proc parseLastMonthDays(expression, value: string): ValueMatcher =
  let normalized = if value.len == 0: "1" else: value
  for item in normalized.split(','):
    let slash = item.find('/')
    if slash >= 0 and item.find('/', slash + 1) >= 0:
      raise calendarError(expression, "invalid last-day repetition")
    let base = if slash >= 0: item[0 ..< slash] else: item
    let repetition = if slash >= 0: item[slash + 1 .. ^1] else: ""

    if ".." in base:
      if slash >= 0:
        raise calendarError(expression, "last-day ranges cannot repeat")
      let bounds = splitOnce(expression, base, "..", "last day range")
      let first = parseUnsigned(expression, bounds.left, "last day")
      let last = parseUnsigned(expression, bounds.right, "last day")
      if first < 1 or last > 31 or first > last:
        raise calendarError(expression, "invalid last-day range")
      result.spans.add ValueSpan(first: first, last: last, step: 1)
    else:
      let highest = parseUnsigned(expression, base, "last day")
      if highest < 1 or highest > 31:
        raise calendarError(expression, "last day is outside 1..31")
      if slash >= 0:
        let step = parseUnsigned(expression, repetition, "last-day repetition")
        if step <= 0:
          raise calendarError(expression, "last-day repetition must be positive")
        let lowest = (highest - 1) mod step + 1
        result.spans.add ValueSpan(first: lowest, last: highest, step: step)
      else:
        result.spans.add ValueSpan(first: highest, last: highest, step: 1)

proc parseDate(expression, value: string): DateFields =
  let firstDash = value.find('-')
  if firstDash <= 0:
    raise calendarError(expression, "date must use Year-Month-Day syntax")
  let yearText = value[0 ..< firstDash]
  let remainder = value[firstDash + 1 .. ^1]
  let tilde = remainder.find('~')

  var monthText: string
  if tilde >= 0:
    if remainder.find('~', tilde + 1) >= 0:
      raise calendarError(expression, "date contains more than one `~`")
    monthText = remainder[0 ..< tilde]
    result.monthDays = MonthDayRule(
      kind: mdrFromEnd,
      lastDays: parseLastMonthDays(expression, remainder[tilde + 1 .. ^1])
    )
  else:
    let secondDash = remainder.find('-')
    if secondDash <= 0 or remainder.find('-', secondDash + 1) >= 0:
      raise calendarError(expression, "date must use Year-Month-Day syntax")
    monthText = remainder[0 ..< secondDash]
    result.monthDays = MonthDayRule(
      kind: mdrAbsolute,
      absoluteDays: parseIntegerMatcher(
        expression, remainder[secondDash + 1 .. ^1], "month day", 1, 31
      )
    )

  result.years = parseIntegerMatcher(expression, yearText, "year", 1, 9999)
  result.months = parseIntegerMatcher(expression, monthText, "month", 1, 12)

proc parseTime(expression, value: string): TimeFields =
  let pieces = value.split(':')
  if pieces.len notin {2, 3}:
    raise calendarError(expression, "time must use Hour:Minute[:Second] syntax")
  result.hours = parseIntegerMatcher(expression, pieces[0], "hour", 0, 23)
  result.minutes = parseIntegerMatcher(expression, pieces[1], "minute", 0, 59)
  result.secondMicros = parseSecondMatcher(
    expression, if pieces.len == 3: pieces[2] else: "0", "second"
  )

proc defaultCalendarSpec(): CalendarSpec =
  CalendarSpec(
    years: allValues(1, 9999),
    months: allValues(1, 12),
    monthDays: MonthDayRule(
      kind: mdrAbsolute,
      absoluteDays: allValues(1, 31)
    ),
    weekdays: allValues(1, 7),
    hours: singleValue(0),
    minutes: singleValue(0),
    secondMicros: singleValue(0),
    timezone: none(Timezone)
  )

proc shorthand(value: string): string =
  case value.toLowerAscii()
  of "minutely": "*-*-* *:*:00"
  of "hourly": "*-*-* *:00:00"
  of "daily": "*-*-* 00:00:00"
  of "monthly": "*-*-01 00:00:00"
  of "weekly": "Mon *-*-* 00:00:00"
  of "yearly", "annually": "*-01-01 00:00:00"
  of "quarterly": "*-01,04,07,10-01 00:00:00"
  of "semiannually": "*-01,07-01 00:00:00"
  else: ""

proc expandShorthand(expression: string): seq[string] =
  result = expression.splitWhitespace()
  let expanded = shorthand(result[0])
  if expanded.len == 0:
    return
  let timezoneToken = if result.len == 2: result[1] else: ""
  if result.len > 2:
    raise calendarError(expression, "too many tokens after shorthand")
  result = expanded.splitWhitespace()
  if timezoneToken.len > 0:
    result.add timezoneToken

proc looksLikeDate(value: string): bool =
  '-' in value or '~' in value

proc looksLikeTime(value: string): bool =
  ':' in value

proc shouldParseWeekday(tokens: openArray[string], position: int): bool =
  if position >= tokens.len or tokens[position].looksLikeDate or
      tokens[position].looksLikeTime:
    return false
  if tokens[position].isWeekdayExpression:
    return true
  position + 1 < tokens.len and
    (tokens[position + 1].looksLikeDate or tokens[position + 1].looksLikeTime)

proc parseCalendarSpec*(expression: string): CalendarSpec =
  let original = expression.strip()
  if original.len == 0:
    raise calendarError(expression, "expression cannot be empty")

  let tokens = expandShorthand(original)
  result = defaultCalendarSpec()
  var position = 0

  if tokens.shouldParseWeekday(position):
    result.weekdays = parseWeekdays(original, tokens[position])
    position.inc

  var sawDate = false
  var sawTime = false
  if position < tokens.len and tokens[position].looksLikeDate:
    let dateFields = parseDate(original, tokens[position])
    result.years = dateFields.years
    result.months = dateFields.months
    result.monthDays = dateFields.monthDays
    sawDate = true
    position.inc
  if position < tokens.len and tokens[position].looksLikeTime:
    let timeFields = parseTime(original, tokens[position])
    result.hours = timeFields.hours
    result.minutes = timeFields.minutes
    result.secondMicros = timeFields.secondMicros
    sawTime = true
    position.inc
  if not sawDate and not sawTime:
    raise calendarError(original, "missing date or time")

  if position < tokens.len:
    if position != tokens.high:
      raise calendarError(original, "unexpected trailing tokens")
    try:
      result.timezone = some(namedTimezone(tokens[position]))
    except ValueError as error:
      raise calendarError(original, error.msg)
    position.inc
  if position != tokens.len:
    raise calendarError(original, "unexpected trailing input")
