#!/usr/bin/env python3
"""Drive palm-davd with python-caldav, a third-party CalDAV client.

    caldav_client.py URL HANDLE APP_PASSWORD

Discovers the principal from the root URL, makes a calendar, stores a
recurring event with a moved instance and a cancelled one, asks for a week
with server-side expansion, syncs with a sync token, and cleans up. Prints
one line per check and exits non-zero on the first failure.
"""
import datetime as dt
import sys

import caldav

url, user, password = sys.argv[1:4]
failures = 0


def check(ok, what):
    global failures
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        failures += 1


client = caldav.DAVClient(url=url, username=user, password=password)
principal = client.principal()
check(principal.url.path == f"/dav/principals/{user}/", f"principal discovered at {principal.url.path}")
home = principal.calendar_home_set
check(str(home.url).endswith(f"/dav/calendars/{user}/"), "calendar-home-set")

# A fresh calendar for the run.
for c in principal.calendars():
    if c.url.path.rstrip("/").endswith("/python-test"):
        c.delete()
cal = principal.make_calendar(name="Python test", cal_id="python-test")
check(cal.get_display_name() == "Python test", "MKCALENDAR with a display name")

STANDUP = """BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//python-caldav test//EN
BEGIN:VTIMEZONE
TZID:Europe/Paris
BEGIN:DAYLIGHT
TZOFFSETFROM:+0100
TZOFFSETTO:+0200
DTSTART:19700329T020000
RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU
END:DAYLIGHT
BEGIN:STANDARD
TZOFFSETFROM:+0200
TZOFFSETTO:+0100
DTSTART:19701025T030000
RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU
END:STANDARD
END:VTIMEZONE
BEGIN:VEVENT
UID:standup-python@palm.test
DTSTAMP:20261019T080000Z
DTSTART;TZID=Europe/Paris:20261019T093000
DTEND;TZID=Europe/Paris:20261019T094500
RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=12
EXDATE;TZID=Europe/Paris:20261021T093000
SUMMARY:Stand-up
END:VEVENT
BEGIN:VEVENT
UID:standup-python@palm.test
DTSTAMP:20261019T080000Z
RECURRENCE-ID;TZID=Europe/Paris:20261023T093000
DTSTART;TZID=Europe/Paris:20261023T110000
DTEND;TZID=Europe/Paris:20261023T113000
SUMMARY:Stand-up (moved to 11:00)
END:VEVENT
END:VCALENDAR
"""
ev = cal.save_event(STANDUP)
check(ev is not None, "PUT a recurring event with an EXDATE and a moved instance")

ONEOFF = """BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//python-caldav test//EN
BEGIN:VEVENT
UID:dentist-python@palm.test
DTSTAMP:20261019T080000Z
DTSTART:20261104T150000Z
DTEND:20261104T153000Z
SUMMARY:Dentist
END:VEVENT
END:VCALENDAR
"""
cal.save_event(ONEOFF)

token = cal.objects_by_sync_token(load_objects=False).sync_token
check(token and "palmy.dev/ns/sync/" in str(token), f"initial sync token {str(token)[-40:]}")

# The week of 19 October: Mon 19, (Wed 21 excluded), Fri 23 moved.
found = cal.search(start=dt.datetime(2026, 10, 19, tzinfo=dt.timezone.utc),
                   end=dt.datetime(2026, 10, 26, tzinfo=dt.timezone.utc), event=True, expand=True)
starts = []
for e in found:
    for comp in e.icalendar_instance.walk("VEVENT"):
        starts.append((comp.get("DTSTART").dt.astimezone(dt.timezone.utc).strftime("%a %d %H:%M"), str(comp.get("SUMMARY"))))
starts.sort()
print("      expanded week:", starts)
check(len(starts) == 2, "time-range query with expand returns 2 instances (one excluded)")
check(("Fri 23 09:00", "Stand-up (moved to 11:00)") in starts, "the moved instance is at 11:00 Paris, 09:00Z")
check(("Mon 19 07:30", "Stand-up") in starts, "Monday is 09:30 Paris, 07:30Z (summer time)")

# After the change to winter time, 09:30 Paris is 08:30Z.
late = cal.search(start=dt.datetime(2026, 10, 26, tzinfo=dt.timezone.utc),
                  end=dt.datetime(2026, 10, 27, tzinfo=dt.timezone.utc), event=True, expand=True)
times = [c.get("DTSTART").dt.astimezone(dt.timezone.utc).strftime("%H:%M")
         for e in late for c in e.icalendar_instance.walk("VEVENT")]
check(times == ["08:30"], f"after the DST change the instance is 08:30Z ({times})")

# A range with only the one-off.
nov = cal.search(start=dt.datetime(2026, 11, 4, tzinfo=dt.timezone.utc),
                 end=dt.datetime(2026, 11, 5, tzinfo=dt.timezone.utc), event=True)
summaries = sorted(str(e.icalendar_component.get("SUMMARY")) for e in nov)
check("Dentist" in summaries, f"time-range finds the one-off ({summaries})")

# Modify, then sync from the token: exactly one change comes back.
dentist = cal.event_by_uid("dentist-python@palm.test")
comp = dentist.icalendar_component
comp["SUMMARY"] = "Dentist (moved)"
dentist.save()
changed = cal.objects_by_sync_token(sync_token=token, load_objects=True)
names = [o.url.path.rsplit("/", 1)[-1] for o in changed]
check(len(names) == 1, f"sync-collection reports one change ({names})")

# Delete: the next sync reports a tombstone.
token2 = changed.sync_token
dentist.delete()
gone = cal.objects_by_sync_token(sync_token=token2, load_objects=False)
check(len(list(gone)) == 1, "a delete is reported by sync-collection")

# A UID clash under a second name is refused (no-uid-conflict).
try:
    resp = client.request(str(cal.url) + "other-name.ics", "PUT", STANDUP,
                          {"Content-Type": "text/calendar; charset=utf-8"})
    status = resp.status
except caldav.lib.error.AuthorizationError:
    status = 403
check(status == 403, f"the same UID under another name is refused ({status}, no-uid-conflict)")

cal.delete()
print(f"{'all checks passed' if failures == 0 else f'{failures} FAILED'}")
sys.exit(1 if failures else 0)
