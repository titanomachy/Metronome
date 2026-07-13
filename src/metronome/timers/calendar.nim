## Shared internal representation for systemd-style calendar expressions.

import std/[options, times]

const
  MicrosPerSecond* = 1_000_000'i64
  MicrosPerMinute* = 60 * MicrosPerSecond
  MicrosPerHour* = 60 * MicrosPerMinute
  MicrosPerDay* = 24 * MicrosPerHour

type
  ValueSpan* = object
    first*: int64
    last*: int64
    step*: int64

  ValueMatcher* = object
    spans*: seq[ValueSpan]

  MonthDayRuleKind* = enum
    mdrAbsolute
    mdrFromEnd

  MonthDayRule* = object
    case kind*: MonthDayRuleKind
    of mdrAbsolute:
      absoluteDays*: ValueMatcher
    of mdrFromEnd:
      lastDays*: ValueMatcher

  CalendarSpec* = object
    years*: ValueMatcher
    months*: ValueMatcher
    monthDays*: MonthDayRule
    weekdays*: ValueMatcher
    hours*: ValueMatcher
    minutes*: ValueMatcher
    secondMicros*: ValueMatcher
    timezone*: Option[Timezone]

proc allValues*(first, last: int64): ValueMatcher =
  ## Construct a matcher containing every value in an inclusive range.
  ValueMatcher(spans: @[ValueSpan(first: first, last: last, step: 1)])

proc singleValue*(value: int64): ValueMatcher =
  ## Construct a matcher containing one value.
  ValueMatcher(spans: @[ValueSpan(first: value, last: value, step: 1)])

proc nextAtOrAfter*(
  matcher: ValueMatcher,
  value: int64
): Option[int64] =
  ## Return the smallest matching value greater than or equal to value.
  ##
  ## The step count is bounded before multiplication, avoiding overflow even
  ## when an input expression contains an extremely large repetition value.
  var found = false
  var selected = 0'i64
  for span in matcher.spans:
    var candidate = span.first
    if value > span.first:
      let distance = value - span.first
      var steps = distance div span.step
      if distance mod span.step != 0:
        steps.inc
      let availableSteps = (span.last - span.first) div span.step
      if steps > availableSteps:
        continue
      candidate = span.first + steps * span.step
    if candidate <= span.last and (not found or candidate < selected):
      selected = candidate
      found = true
  if found:
    some(selected)
  else:
    none(int64)

proc contains*(matcher: ValueMatcher, value: int64): bool =
  ## Return whether value belongs to one of the matcher's spans.
  for span in matcher.spans:
    if value >= span.first and value <= span.last and
        (value - span.first) mod span.step == 0:
      return true
