## Next-run evaluator for parsed systemd-style calendar expressions.

import std/[options, times]

import ./calendar

type
  WallClock = object
    year: int
    month: int
    day: int
    hour: int
    minute: int
    second: int
    nanosecond: int

  WallTimeResolution = object
    exact: bool
    value: DateTime
    nextThreshold: int64

proc findTimeAtOrAfter(
  spec: CalendarSpec,
  threshold: int64
): Option[int64] =
  if threshold >= MicrosPerDay:
    return none(int64)

  let firstHour = threshold div MicrosPerHour
  var hourSearch = firstHour
  while hourSearch <= 23:
    let hourOption = spec.hours.nextAtOrAfter(hourSearch)
    if hourOption.isNone:
      return none(int64)
    let hour = hourOption.get()
    let firstMinute = if hour == firstHour:
      (threshold mod MicrosPerHour) div MicrosPerMinute
    else:
      0
    var minuteSearch = firstMinute
    while minuteSearch <= 59:
      let minuteOption = spec.minutes.nextAtOrAfter(minuteSearch)
      if minuteOption.isNone:
        break
      let minute = minuteOption.get()
      let firstSecond = if hour == firstHour and minute == firstMinute:
        threshold mod MicrosPerMinute
      else:
        0
      let secondOption = spec.secondMicros.nextAtOrAfter(firstSecond)
      if secondOption.isSome:
        return some(
          hour * MicrosPerHour + minute * MicrosPerMinute + secondOption.get()
        )
      minuteSearch = minute + 1
    hourSearch = hour + 1
  none(int64)

proc matchesDate(spec: CalendarSpec, year, month, day: int): bool =
  if not spec.years.contains(year) or not spec.months.contains(month):
    return false
  case spec.monthDays.kind
  of mdrAbsolute:
    if not spec.monthDays.absoluteDays.contains(day):
      return false
  of mdrFromEnd:
    let offset = getDaysInMonth(Month(month), year) - day + 1
    if not spec.monthDays.lastDays.contains(offset):
      return false
  let weekday = ord(getDayOfWeek(day, Month(month), year)) + 1
  spec.weekdays.contains(weekday)

proc wallClock(
  year, month, day: int,
  microsOfDay: int64
): WallClock =
  result.year = year
  result.month = month
  result.day = day
  result.hour = int(microsOfDay div MicrosPerHour)
  result.minute = int((microsOfDay mod MicrosPerHour) div MicrosPerMinute)
  let withinMinute = microsOfDay mod MicrosPerMinute
  result.second = int(withinMinute div MicrosPerSecond)
  result.nanosecond = int(withinMinute mod MicrosPerSecond) * 1_000

proc microsOfDay(value: WallClock): int64 =
  (int64(value.hour) * 3600 + int64(value.minute) * 60 +
    int64(value.second)) * MicrosPerSecond +
    int64(value.nanosecond div 1_000)

proc microsOfDay(value: DateTime): int64 =
  (int64(value.hour) * 3600 + int64(value.minute) * 60 +
    int64(value.second)) * MicrosPerSecond +
    int64(value.nanosecond div 1_000)

proc sameWallTime(value: DateTime, wall: WallClock): bool =
  value.year == wall.year and ord(value.month) == wall.month and
    value.monthday == wall.day and value.hour == wall.hour and
    value.minute == wall.minute and value.second == wall.second and
    value.nanosecond == wall.nanosecond

proc dateIsAfter(value: DateTime, wall: WallClock): bool =
  if value.year != wall.year:
    return value.year > wall.year
  if ord(value.month) != wall.month:
    return ord(value.month) > wall.month
  value.monthday > wall.day

proc resolveWallTime(wall: WallClock, zone: Timezone): WallTimeResolution =
  result.value = dateTime(
    wall.year,
    Month(wall.month),
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
    wall.nanosecond,
    zone
  )
  result.exact = result.value.sameWallTime(wall)
  result.nextThreshold = wall.microsOfDay + 1
  if result.exact:
    return

  # Nim normalizes a nonexistent wall time forward across a DST gap. Jump to
  # that boundary instead of testing every selected second or microsecond in
  # the missing interval.
  if result.value.dateIsAfter(wall):
    result.nextThreshold = MicrosPerDay
  elif result.value.year == wall.year and ord(result.value.month) == wall.month and
      result.value.monthday == wall.day:
    result.nextThreshold = max(result.nextThreshold, result.value.microsOfDay)

proc getNext*(
  spec: CalendarSpec,
  current: DateTime
): Option[DateTime] {.gcsafe, raises: [].} =
  let zone = if spec.timezone.isSome: spec.timezone.get() else: current.timezone
  let localCurrent = current.toTime.inZone(zone)
  let currentInstant = current.toTime
  var yearSearch = localCurrent.year

  while yearSearch <= 9999:
    let yearOption = spec.years.nextAtOrAfter(yearSearch)
    if yearOption.isNone:
      return none(DateTime)
    let year = int(yearOption.get())
    let firstMonth = if year == localCurrent.year: ord(localCurrent.month) else: 1
    var monthSearch = firstMonth

    while monthSearch <= 12:
      let monthOption = spec.months.nextAtOrAfter(monthSearch)
      if monthOption.isNone:
        break
      let month = int(monthOption.get())
      let firstDay = if year == localCurrent.year and
          month == ord(localCurrent.month): localCurrent.monthday else: 1
      let finalDay = getDaysInMonth(Month(month), year)

      for day in firstDay .. finalDay:
        if not spec.matchesDate(year, month, day):
          continue

        let sameDate = year == localCurrent.year and
          month == ord(localCurrent.month) and day == localCurrent.monthday
        var threshold = if sameDate:
          localCurrent.microsOfDay + 1
        else:
          0'i64

        while threshold < MicrosPerDay:
          let timeOption = spec.findTimeAtOrAfter(threshold)
          if timeOption.isNone:
            break
          let resolution = resolveWallTime(
            wallClock(year, month, day, timeOption.get()), zone
          )
          if resolution.exact and resolution.value.toTime > currentInstant:
            return some(resolution.value.toTime.inZone(current.timezone))
          threshold = resolution.nextThreshold

      monthSearch = month + 1
    yearSearch = year + 1

  none(DateTime)
