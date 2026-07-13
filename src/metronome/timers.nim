## # Schedule by Timer
##
## This optional module implements systemd-style ``OnCalendar`` expressions.
## Importing it also imports Metronome's embedded IANA timezone database; an
## application importing only ``metronome`` does not include either feature.
##
## The calendar shape is::
##
##     [DayOfWeek] Year-Month-Day Hour:Minute:Second[.Microseconds] [TimeZone]
##
## For example::
##
##     import metronome
##     import metronome/timers
##
##     scheduler nightly:
##       timer(
##         onCalendar="*-*-* 02:00:00 Europe/Amsterdam",
##         async=true
##       ):
##         echo "Running at 02:00 in Amsterdam"
##
## Calendar deadlines are calculated to one microsecond. Metronome uses a
## millisecond event-loop wait, however, so dispatch is best-effort and is not
## a real-time guarantee. Nonexistent local times are skipped at DST gaps;
## ambiguous local times select the earlier occurrence.
##
## Calendar fields accept ``*``, lists separated by commas, ascending ``..``
## ranges, and ``/`` repetitions with an explicit start value. An optional
## English weekday prefix is combined with the date using AND semantics. The
## date also accepts systemd's ``~`` last-day form. Supported shorthands are
## ``minutely``, ``hourly``, ``daily``, ``monthly``, ``weekly``, ``yearly``,
## ``annually``, ``quarterly``, and ``semiannually``.
##
## The timezone suffix may be ``UTC`` or an exact name from Metronome's
## embedded IANA catalog. If omitted, the timezone of the ``DateTime`` passed
## to ``getNext`` is used. The next result is returned in that caller timezone.
##
## This module intentionally does not parse complete systemd ``.timer`` units
## and does not implement ``AccuracySec``, persistent catch-up, randomized
## delay, monotonic boot timers, or wake-from-suspend.

import std/[options, times]

import ./scheduler
import ./timers/calendar
import ./timers/calendarparser
import ./timers/calendareval

type
  CalendarTimer* = object
    specs: seq[CalendarSpec]

proc newTimer*(onCalendar: string): CalendarTimer =
  ## Parse one systemd-style ``OnCalendar`` expression.
  CalendarTimer(specs: @[parseCalendarSpec(onCalendar)])

proc newTimer*(onCalendar: openArray[string]): CalendarTimer =
  ## Parse repeated ``OnCalendar`` expressions into one timer.
  if onCalendar.len == 0:
    raise newException(ValueError, "OnCalendar expression list cannot be empty")
  for expression in onCalendar:
    result.specs.add parseCalendarSpec(expression)

proc getNext*(
  timer: CalendarTimer,
  current: DateTime
): Option[DateTime] {.gcsafe, raises: [].} =
  ## Return the first matching instant strictly later than current.
  ##
  ## When multiple expressions match the same instant, it is returned once.
  for spec in timer.specs:
    let candidate = spec.getNext(current)
    if candidate.isSome and (result.isNone or
        candidate.get().toTime < result.get().toTime):
      result = candidate

proc timerNextRun(timer: CalendarTimer): NextRunProc =
  result = proc (current: DateTime): Option[DateTime] {.
      closure, gcsafe, raises: []
    .} =
    timer.getNext(current)

proc initTimerBeater*(
  timer: CalendarTimer,
  asyncProc: BeaterAsyncProc,
  startTime: Option[DateTime] = none(DateTime),
  endTime: Option[DateTime] = none(DateTime),
  id: string = "",
  throttleNum: int = 1,
  errorHandler: JobErrorHandler = nil,
): Beater =
  ## Initialize an async beater driven by a parsed calendar timer.
  initBeater(
    nextRunProc = timer.timerNextRun(),
    asyncProc = asyncProc,
    startTime = startTime,
    endTime = endTime,
    id = id,
    throttleNum = throttleNum,
    errorHandler = errorHandler,
  )

proc initTimerBeater*(
  timer: CalendarTimer,
  threadProc: BeaterThreadProc,
  startTime: Option[DateTime] = none(DateTime),
  endTime: Option[DateTime] = none(DateTime),
  id: string = "",
  throttleNum: int = 1,
  errorHandler: JobErrorHandler = nil,
): Beater =
  ## Initialize a thread-backed beater driven by a parsed calendar timer.
  initBeater(
    nextRunProc = timer.timerNextRun(),
    threadProc = threadProc,
    startTime = startTime,
    endTime = endTime,
    id = id,
    throttleNum = throttleNum,
    errorHandler = errorHandler,
  )
