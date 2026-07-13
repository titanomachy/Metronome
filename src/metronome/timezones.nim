## # Named IANA timezones
##
## This optional module resolves IANA names using a database embedded at
## compile time. It does not read the operating system's zoneinfo files and it
## never downloads data at runtime.
##
## Import it separately from the main scheduler module::
##
##     import std/[asyncdispatch, times]
##     import metronome
##     import metronome/timezones
##
##     let amsterdam = namedTimezone("Europe/Amsterdam")
##
##     scheduler sched:
##       cron(hour="9", minute="0", timezone=amsterdam, async=true):
##         echo "09:00 in Amsterdam"
##
## A named zone preserves its local wall-clock schedule across daylight-saving
## changes. The embedded database is deterministic and cross-platform, but it
## should be updated when IANA publishes changed government rules.
##
## Local-clock edge cases follow these rules:
##
## * a nonexistent time during a forward jump is moved forward by the gap;
## * an ambiguous time during a backward jump selects the earlier occurrence.
##
## Names are exact and case-sensitive. Canonical IANA names and the aliases in
## the bundled release are supported, including ``Etc/UTC`` and ``UTC``.
## ``LOCAL``, numeric offsets, abbreviations that are not themselves IANA
## identifiers (such as ``CEST``), and filesystem paths are not accepted.

import std/times

import ./timezones/[catalog, tzif]

proc namedTimezone*(name: string): Timezone {.raises: [ValueError].} =
  ## Resolve an exact IANA timezone name using Metronome's embedded database.
  ##
  ## Raises ``ValueError`` for an empty, malformed, case-mismatched, or unknown
  ## name. Resolution constructs an independent ``times.Timezone`` whose
  ## callbacks read immutable transition data and can be shared by scheduler
  ## jobs.
  if name.len == 0:
    raise newException(ValueError, "Timezone name cannot be empty")

  let data = catalogZone(name)
  if data.len == 0:
    raise newException(ValueError, "Unknown IANA timezone: " & name)
  newTimezoneFromTzif(name, data)

proc timezoneDatabaseVersion*(): string {.inline, raises: [].} =
  ## Return the embedded IANA ``tzdata`` release, for example ``"2026c"``.
  catalogDataVersion()

proc timezoneNames*(): seq[string] {.raises: [].} =
  ## Return all supported canonical IANA names and aliases in sorted order.
  catalogNames()
