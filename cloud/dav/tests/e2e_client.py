#!/usr/bin/env python3
"""The third-party side of e2e.sh, with python-caldav.

    e2e_client.py URL USER PW add CALENDAR ICS_TEXT
    e2e_client.py URL USER PW override CALENDAR UID RID_UTC NEW_START_UTC NEW_END_UTC
    e2e_client.py URL USER PW events CALENDAR START END     (YYYYMMDD; expanded, UTC)
    e2e_client.py URL USER PW calendars

CALENDAR is the last path segment (default, maya~default ...).
"""
import datetime as dt
import sys

import caldav

url, user, pw, cmd = sys.argv[1:5]
args = sys.argv[5:]
client = caldav.DAVClient(url=url, username=user, password=pw)
principal = client.principal()


def calendar(seg):
    for c in principal.calendars():
        if c.url.path.rstrip("/").split("/")[-1] == seg:
            return c
    raise SystemExit(f"no calendar {seg} for {user}")


def utc(s):
    return dt.datetime.strptime(s, "%Y%m%d").replace(tzinfo=dt.timezone.utc)


if cmd == "calendars":
    for c in principal.calendars():
        print(c.url.path)
elif cmd == "add":
    calendar(args[0]).save_event(args[1])
    print("stored")
elif cmd == "override":
    seg, uid, rid, start, end = args
    ev = calendar(seg).event_by_uid(uid)
    cal = ev.icalendar_instance
    master = next(c for c in cal.walk("VEVENT") if c.get("RECURRENCE-ID") is None)
    import icalendar

    o = icalendar.Event()
    o.add("UID", uid)
    o.add("DTSTAMP", dt.datetime.now(dt.timezone.utc))
    o.add("RECURRENCE-ID", dt.datetime.strptime(rid, "%Y%m%dT%H%M%SZ").replace(tzinfo=dt.timezone.utc))
    o.add("DTSTART", dt.datetime.strptime(start, "%Y%m%dT%H%M%SZ").replace(tzinfo=dt.timezone.utc))
    o.add("DTEND", dt.datetime.strptime(end, "%Y%m%dT%H%M%SZ").replace(tzinfo=dt.timezone.utc))
    o.add("SUMMARY", str(master.get("SUMMARY")) + " (moved by python-caldav)")
    cal.add_component(o)
    ev.icalendar_instance = cal
    ev.save()
    print("override stored")
elif cmd == "events":
    seg, start, end = args
    out = []
    for e in calendar(seg).search(start=utc(start), end=utc(end), event=True, expand=True):
        for c in e.icalendar_instance.walk("VEVENT"):
            when = c.get("DTSTART").dt
            label = (f"{when.astimezone(dt.timezone.utc):%a %d %H:%M}Z" if isinstance(when, dt.datetime)
                     else f"{when:%a %d} all day")
            out.append(f"{label}  {c.get('SUMMARY')}")
    print("\n".join(sorted(out)))
