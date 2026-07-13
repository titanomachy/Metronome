import std/[algorithm, asyncdispatch, options, times, unittest]

import metronome
import metronome/timezones
import metronome/timezones/posixrule

proc noop(): Future[void] {.async.} =
  discard

suite "named IANA timezones":
  test "reports the pinned database and sorted names":
    check timezoneDatabaseVersion() == "2026c"
    let names = timezoneNames()
    check names.len > 500
    check names.isSorted(system.cmp[string])
    check "Europe/Amsterdam" in names
    check "America/Chicago" in names
    check "US/Central" in names
    check "Etc/UTC" in names
    check "UTC" in names

  test "rejects unknown and malformed names":
    for name in [
      "",
      "europe/amsterdam",
      "Europe/Does_Not_Exist",
      "../Europe/Amsterdam",
      "/usr/share/zoneinfo/Europe/Amsterdam",
      "CEST",
      "LOCAL"
    ]:
      expect ValueError:
        discard namedTimezone(name)

  test "resolves canonical names and aliases":
    let chicago = namedTimezone("America/Chicago")
    let centralAlias = namedTimezone("US/Central")
    let instant = dateTime(2040, mJul, 1, 12, 0, 0, 0, utc()).toTime
    let canonical = instant.inZone(chicago)
    let alias = instant.inZone(centralAlias)
    check canonical.utcOffset == alias.utcOffset
    check canonical.isDst == alias.isDst
    check canonical.hour == alias.hour

    check namedTimezone("Etc/UTC").name == "Etc/UTC"
    check namedTimezone("UTC").name == "UTC"

  test "constructs every catalog entry":
    let representative = dateTime(2040, mJul, 1, 12, 0, 0, 0, utc()).toTime
    for name in timezoneNames():
      let zone = namedTimezone(name)
      check zone.name == name
      discard representative.inZone(zone)

  test "converts Amsterdam UTC instants in winter and summer":
    let amsterdam = namedTimezone("Europe/Amsterdam")
    let winter = dateTime(2026, mJan, 15, 12, 0, 0, 0, utc()).inZone(amsterdam)
    let summer = dateTime(2026, mJul, 15, 12, 0, 0, 0, utc()).inZone(amsterdam)

    check winter.hour == 13
    check winter.utcOffset == -3600
    check not winter.isDst
    check summer.hour == 14
    check summer.utcOffset == -7200
    check summer.isDst

  test "converts Chicago UTC instants in winter and summer":
    let chicago = namedTimezone("America/Chicago")
    let winter = dateTime(2026, mJan, 15, 12, 0, 0, 0, utc()).inZone(chicago)
    let summer = dateTime(2026, mJul, 15, 12, 0, 0, 0, utc()).inZone(chicago)

    check winter.hour == 6
    check winter.utcOffset == 6 * 3600
    check not winter.isDst
    check summer.hour == 7
    check summer.utcOffset == 5 * 3600
    check summer.isDst

  test "converts local wall times back to absolute instants":
    let amsterdam = namedTimezone("Europe/Amsterdam")
    let chicago = namedTimezone("America/Chicago")

    check dateTime(2026, mJan, 15, 9, 0, 0, 0, amsterdam).toTime ==
      dateTime(2026, mJan, 15, 8, 0, 0, 0, utc()).toTime
    check dateTime(2026, mJul, 15, 9, 0, 0, 0, amsterdam).toTime ==
      dateTime(2026, mJul, 15, 7, 0, 0, 0, utc()).toTime
    check dateTime(2026, mJan, 15, 9, 0, 0, 0, chicago).toTime ==
      dateTime(2026, mJan, 15, 15, 0, 0, 0, utc()).toTime
    check dateTime(2026, mJul, 15, 9, 0, 0, 0, chicago).toTime ==
      dateTime(2026, mJul, 15, 14, 0, 0, 0, utc()).toTime

  test "handles the exact Amsterdam spring-forward boundary":
    let amsterdam = namedTimezone("Europe/Amsterdam")
    let before = dateTime(2026, mMar, 29, 0, 59, 59, 0, utc()).inZone(amsterdam)
    let after = dateTime(2026, mMar, 29, 1, 0, 0, 0, utc()).inZone(amsterdam)

    check before.hour == 1
    check before.minute == 59
    check before.utcOffset == -3600
    check not before.isDst
    check after.hour == 3
    check after.minute == 0
    check after.utcOffset == -7200
    check after.isDst

  test "normalizes a nonexistent Amsterdam time forward":
    let amsterdam = namedTimezone("Europe/Amsterdam")
    let normalized = dateTime(2026, mMar, 29, 2, 30, 0, 0, amsterdam)

    check normalized.hour == 3
    check normalized.minute == 30
    check normalized.isDst
    check normalized.toTime ==
      dateTime(2026, mMar, 29, 1, 30, 0, 0, utc()).toTime

  test "chooses the earlier occurrence of an ambiguous Amsterdam time":
    let amsterdam = namedTimezone("Europe/Amsterdam")
    let ambiguous = dateTime(2026, mOct, 25, 2, 30, 0, 0, amsterdam)

    check ambiguous.isDst
    check ambiguous.utcOffset == -7200
    check ambiguous.toTime ==
      dateTime(2026, mOct, 25, 0, 30, 0, 0, utc()).toTime

  test "handles the exact Amsterdam fall-back boundary":
    let amsterdam = namedTimezone("Europe/Amsterdam")
    let before = dateTime(2026, mOct, 25, 0, 59, 59, 0, utc()).inZone(amsterdam)
    let after = dateTime(2026, mOct, 25, 1, 0, 0, 0, utc()).inZone(amsterdam)

    check before.hour == 2
    check before.minute == 59
    check before.isDst
    check before.utcOffset == -7200
    check after.hour == 2
    check after.minute == 0
    check not after.isDst
    check after.utcOffset == -3600

  test "handles Chicago DST gaps and overlaps":
    let chicago = namedTimezone("America/Chicago")
    let missing = dateTime(2026, mMar, 8, 2, 30, 0, 0, chicago)
    let ambiguous = dateTime(2026, mNov, 1, 1, 30, 0, 0, chicago)

    check missing.hour == 3
    check missing.minute == 30
    check missing.isDst
    check missing.toTime == dateTime(2026, mMar, 8, 8, 30, 0, 0, utc()).toTime
    check ambiguous.isDst
    check ambiguous.utcOffset == 5 * 3600
    check ambiguous.toTime == dateTime(2026, mNov, 1, 6, 30, 0, 0, utc()).toTime

  test "retains historical pre-1970 offsets":
    let amsterdam = namedTimezone("Europe/Amsterdam")
    let historical = dateTime(1942, mJul, 1, 0, 0, 0, 0, utc()).inZone(amsterdam)
    check historical.utcOffset == -7200
    check historical.isDst

  test "applies recurring rules after 2037":
    let amsterdam = namedTimezone("Europe/Amsterdam")
    let chicago = namedTimezone("America/Chicago")

    check dateTime(2040, mJan, 15, 12, 0, 0, 0, utc()).inZone(amsterdam).utcOffset == -3600
    check dateTime(2040, mJul, 15, 12, 0, 0, 0, utc()).inZone(amsterdam).utcOffset == -7200
    check dateTime(2040, mJan, 15, 12, 0, 0, 0, utc()).inZone(chicago).utcOffset == 6 * 3600
    check dateTime(2040, mJul, 15, 12, 0, 0, 0, utc()).inZone(chicago).utcOffset == 5 * 3600

  test "keeps a 09:00 Amsterdam cron at its local wall-clock hour":
    let amsterdam = namedTimezone("Europe/Amsterdam")
    let beater = initBeater(
      newCron(hour = "9", minute = "0"),
      noop,
      timezone = some(amsterdam)
    )

    let winterCurrent = dateTime(2026, mJan, 15, 7, 30, 0, 0, utc())
    let summerCurrent = dateTime(2026, mJul, 15, 6, 30, 0, 0, utc())
    check beater.fireTime(none(DateTime), winterCurrent).get ==
      dateTime(2026, mJan, 15, 8, 0, 0, 0, utc())
    check beater.fireTime(none(DateTime), summerCurrent).get ==
      dateTime(2026, mJul, 15, 7, 0, 0, 0, utc())

  test "Amsterdam and Chicago cron jobs can coexist":
    let current = dateTime(2026, mJul, 15, 6, 30, 0, 0, utc())
    let amsterdamJob = initBeater(
      newCron(hour = "9", minute = "0"),
      noop,
      timezone = some(namedTimezone("Europe/Amsterdam"))
    )
    let chicagoJob = initBeater(
      newCron(hour = "9", minute = "0"),
      noop,
      timezone = some(namedTimezone("America/Chicago"))
    )

    check amsterdamJob.fireTime(none(DateTime), current).get ==
      dateTime(2026, mJul, 15, 7, 0, 0, 0, utc())
    check chicagoJob.fireTime(none(DateTime), current).get ==
      dateTime(2026, mJul, 15, 14, 0, 0, 0, utc())

  test "one resolved timezone can be shared by cron jobs":
    let shared = namedTimezone("Europe/Amsterdam")
    let morning = initBeater(
      newCron(hour = "9", minute = "0"),
      noop,
      timezone = some(shared)
    )
    let evening = initBeater(
      newCron(hour = "17", minute = "0"),
      noop,
      timezone = some(shared)
    )
    let current = dateTime(2026, mJul, 15, 6, 30, 0, 0, utc())

    check morning.fireTime(none(DateTime), current).get.hour == 7
    check evening.fireTime(none(DateTime), current).get.hour == 15

suite "POSIX TZif footer rules":
  test "parses month, Julian, and zero-based Julian forms":
    let monthRule = parsePosixRule("CET-1CEST,M3.5.0/-2,M10.5.0/3")
    check monthRule.standardOffset == -3600
    check monthRule.daylightOffset == -7200
    check monthRule.daylightStart.seconds == -2 * 3600
    check monthRule.daylightEnd.seconds == 3 * 3600

    let julianRule = parsePosixRule("STD0DST,J60/2,J300/2")
    check julianRule.daylightStart.day.dayOffset(2025) == 59
    check julianRule.daylightStart.day.dayOffset(2024) == 60

    let zeroRule = parsePosixRule("STD0DST,59/2,300/2")
    check zeroRule.daylightStart.day.dayOffset(2025) == 59
    check zeroRule.daylightStart.day.dayOffset(2024) == 59

  test "accepts transition clocks beyond the normal day":
    let rule = parsePosixRule("EET-2EEST,M3.4.4/50,M10.4.4/-2")
    check rule.daylightStart.seconds == 50 * 3600
    check rule.daylightEnd.seconds == -2 * 3600

  test "rejects invalid future rules":
    for rule in [
      "",
      "AB0",
      "STD0DST",
      "STD0DST,M13.1.0,M10.1.0",
      "STD0DST,J0,J365",
      "STD0DST,366,1"
    ]:
      expect ValueError:
        discard parsePosixRule(rule)
