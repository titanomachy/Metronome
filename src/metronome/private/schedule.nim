## Internal nominal schedule calculations; not a supported application API.
## Inputs are explicit and built-in calculations are deterministic. Callbacks
## may carry mutable state. Execution, clocks, jitter/RNG, and lifecycle state
## belong to the scheduler; dependencies here are stdlib and the cron evaluator.
##
## prev is a nominal cadence input for intervals and a consumed marker for
## one-shots; cron and custom calculations query current instead. startTime
## anchors interval alignment and adjusts future custom queries, but is not a
## cron lower bound. Helpers preserve per-kind precision and timezone rules.
## The scheduler adapter filters nominal candidates with withinEndTime before
## applying jitter, then filters effective deadlines again. No lifecycle state,
## throttle capacity, RNG state, or actual launch timestamp enters calculation.

import std/[options, times]
from ../cron/cron import Cron, getNext

proc intervalMilliseconds*(startTime: DateTime, interval: TimeInterval): int64 =
  ## Measure a calendar-relative interval at the supplied anchor.
  ## Months and years keep std/times arithmetic; only the resulting duration
  ## is measured in whole milliseconds (including truncation below 1 ms).
  (startTime + interval - startTime).inMilliseconds

proc intervalNextRun*(
  interval: TimeInterval,
  startTime: DateTime,
  prev: Option[DateTime],
  current: DateTime
): Option[DateTime] =
  ## prev is the previous nominal occurrence, never an actual launch or jittered
  ## deadline. Initial alignment measures milliseconds at startTime; subsequent
  ## occurrences add the calendar-relative interval even when still overdue.
  ## An initial query at a past cadence boundary selects the next full interval.
  ## Preserve current's fractional milliseconds when adding the remaining wait.
  ## Non-positive measured lengths return current for a past anchor; they do
  ## not change future-start selection or calendar-relative addition to prev.
  some(
    if prev.isNone:
      if startTime >= current:
        startTime
      else:
        let passedMs = (current - startTime).inMilliseconds
        let intervalLen = intervalMilliseconds(startTime, interval)
        if intervalLen <= 0:
          current
        else:
          let leftMs = intervalLen - passedMs mod intervalLen
          current + initDuration(milliseconds=leftMs)
    else:
      prev.get() + interval
  )

proc cronNextRun*(
  cron: Cron,
  timezone: Option[Timezone],
  current: DateTime
): Option[DateTime] =
  ## Cron queries current, independently of the beater's start or prior run.
  ## Matching in a configured zone returns an instant in the caller's zone.
  ## The existing evaluator owns boundary rounding and matching semantics.
  if timezone.isSome:
    let zonedNow = current.inZone(timezone.get())
    let zonedNext = cron.getNext(zonedNow)
    if zonedNext.isSome:
      some(zonedNext.get().toTime.inZone(current.timezone))
    else:
      none(DateTime)
  else:
    cron.getNext(current)

proc customNextRun*(
  nextRunProc: proc (current: DateTime): Option[DateTime] {.
    closure, gcsafe, raises: []
  .},
  startTime: DateTime,
  current: DateTime
): Option[DateTime] =
  ## Accept the structural NextRunProc signature so its public definition stays
  ## in scheduler without an import cycle. The callback is supplied directly.
  ## It must be non-nil and return the first instant strictly after its input
  ## or none. Querying just before a future start includes that lower bound.
  ## The caller validates non-nil callbacks. Invoke once without rounding or
  ## changing the returned timezone; captured mutable state can affect results.
  if startTime > current:
    nextRunProc(startTime - initDuration(nanoseconds=1))
  else:
    nextRunProc(current)

proc onceNextRun*(
  deadline: DateTime,
  prev: Option[DateTime]
): Option[DateTime] =
  ## A pending one-shot retains its precise deadline even when overdue.
  ## Any previous occurrence means it has been consumed; no clock is needed.
  if prev.isNone:
    some(deadline)
  else:
    none(DateTime)

proc withinEndTime*(
  candidate: Option[DateTime],
  endTime: Option[DateTime]
): Option[DateTime] =
  ## The nominal upper bound is inclusive. Execution also checks after jitter.
  if endTime.isSome and candidate.isSome and candidate.get() > endTime.get():
    none(DateTime)
  else:
    candidate
