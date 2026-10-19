#!/usr/bin/env python3
"""Two people, three identities, one stock CalDAV client (python-caldav).

    scheduling.py DAV_URL GATEWAY_URL ALICE_PW ALICE_WORK_PW BOB_PW

The *_PW arguments are app passwords for the identities alice, alice-work
and bob. The gateway is used only to sign Alice in (email + password) for
the sharing grant, which is a row the app makes, not a DAV request.

Checks: implicit scheduling between local identities (REQUEST delivered to
the attendee's calendar, REPLY back to the organizer, CANCEL), the outbound
queue for an outside address, free/busy opt-in, a read-only share with
revocation, and isolation between identities of the same person.
"""
import json
import re
import sys
import time
import urllib.request

import caldav
from caldav.lib import error as dav_error

dav, gateway, alice_pw, work_pw, bob_pw = sys.argv[1:6]
ANON = ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9"
        ".CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0")
failures = 0


def check(ok, what):
    global failures
    print(("ok    " if ok else "FAIL  ") + what)
    if not ok:
        failures += 1


def client(user, pw):
    return caldav.DAVClient(url=dav, username=user, password=pw)


def default_cal(c):
    for cal in c.principal().calendars():
        if cal.url.path.rstrip("/").endswith("/default"):
            return cal
    raise SystemExit("no default calendar")


def partstat(ics_text, who):
    for line in re.sub(r"\r?\n[ \t]", "", ics_text).splitlines():
        if line.startswith("ATTENDEE") and line.lower().endswith(who):
            for part in line.split(":")[0].split(";"):
                if part.startswith("PARTSTAT="):
                    return part[9:]
    return None


def param(ics_text, who, name):
    for line in re.sub(r"\r?\n[ \t]", "", ics_text).splitlines():
        if line.startswith("ATTENDEE") and line.lower().endswith(who):
            for part in line.split(":")[0].split(";"):
                if part.startswith(name + "="):
                    return part[len(name) + 1:]
    return None


def rest(method, path, token, body=None):
    req = urllib.request.Request(gateway + path, method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"apikey": ANON, "Authorization": "Bearer " + token,
                                          "Content-Type": "application/json", "Prefer": "return=representation"})
    with urllib.request.urlopen(req) as r:
        text = r.read().decode()
        return json.loads(text) if text else None


alice, work, bob = client("alice", alice_pw), client("alice-work", work_pw), client("bob", bob_pw)
a_cal, b_cal = default_cal(alice), default_cal(bob)
OPT = """<d:propertyupdate xmlns:d="DAV:" xmlns:p="https://palmframe.dev/ns/dav">
<d:set><d:prop><p:public-freebusy>%s</p:public-freebusy></d:prop></d:set></d:propertyupdate>"""
bob.proppatch(str(b_cal.url), OPT % "false")
UID = f"lunch-{int(time.time())}@palm.test"

INVITE = f"""BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//scheduling test//EN
BEGIN:VEVENT
UID:{UID}
DTSTAMP:20261019T090000Z
DTSTART:20261029T113000Z
DTEND:20261029T130000Z
SUMMARY:Lunch: the calendar server
ORGANIZER;CN=Alice Martin:mailto:alice@palm.test
ATTENDEE;CN=Alice Martin;PARTSTAT=ACCEPTED:mailto:alice@palm.test
ATTENDEE;CN=Bob Okafor;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:bob@palm.test
ATTENDEE;CN=Carol;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:carol@example.com
SEQUENCE:0
END:VEVENT
END:VCALENDAR
"""

# 1. Alice invites Bob and Carol by storing the event.
a_cal.save_event(INVITE)
mine = a_cal.event_by_uid(UID).data
check(param(mine, "mailto:bob@palm.test", "SCHEDULE-STATUS") == "1.2",
      "organizer copy: Bob's SCHEDULE-STATUS is 1.2 (delivered)")
check(param(mine, "mailto:carol@example.com", "SCHEDULE-STATUS") == "5.1",
      "organizer copy: Carol's SCHEDULE-STATUS is 5.1 (outbound mail not enabled)")

# 2. Bob's server-side inbox delivery and auto-add.
inbox = bob.principal().schedule_inbox()
items = [i.data for i in inbox.get_items()]
check(any(UID in d and "METHOD:REQUEST" in d for d in items), "Bob's schedule-inbox holds the REQUEST")
b_copy = b_cal.event_by_uid(UID)
check(partstat(b_copy.data, "mailto:bob@palm.test") == "NEEDS-ACTION",
      "the invitation is in Bob's calendar with PARTSTAT=NEEDS-ACTION")

# 3. Bob accepts by changing his own PARTSTAT (as Apple Calendar or Thunderbird do).
b_copy.data = re.sub(r"\r?\n[ \t]", "", b_copy.data).replace("PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:bob@palm.test",
                                  "PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:bob@palm.test")
b_copy.save()
alice.principal().schedule_inbox().get_items()  # Alice looks at her calendars
mine = a_cal.event_by_uid(UID).data
check(partstat(mine, "mailto:bob@palm.test") == "ACCEPTED", "the REPLY reached Alice: Bob is ACCEPTED in her copy")

# 4. Alice moves the lunch: Bob's copy follows.
ev = a_cal.event_by_uid(UID)
ev.data = ev.data.replace("DTSTART:20261029T113000Z", "DTSTART:20261029T120000Z").replace(
    "DTEND:20261029T130000Z", "DTEND:20261029T133000Z").replace("SEQUENCE:0", "SEQUENCE:1")
ev.save()
bob.principal().schedule_inbox().get_items()
check("DTSTART:20261029T120000Z" in b_cal.event_by_uid(UID).data, "an update from the organizer moves Bob's copy")

# 5. The outside address is queued, not sent.
token = json.loads(urllib.request.urlopen(urllib.request.Request(
    gateway + "/auth/v1/token?grant_type=password", method="POST",
    data=json.dumps({"email": "alice@example.test", "password": "correct horse battery"}).encode(),
    headers={"apikey": ANON, "Content-Type": "application/json"})).read())["access_token"]
queued = rest("GET", f"/rest/v1/dav_itip?uid=eq.{UID}&recipient_address=eq.mailto:carol@example.com&select=method,status", token)
check(len(queued) >= 1 and all(q["status"] == "not sent: outbound not enabled" for q in queued),
      f"Carol's invitation is queued: {queued[0]['status'] if queued else 'missing'}")

# 6. Free/busy: nothing until Bob opts in, then his accepted lunch shows.
FB = """BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//scheduling test//EN
METHOD:REQUEST
BEGIN:VFREEBUSY
UID:fb-1@palm.test
DTSTAMP:20261019T090000Z
DTSTART:20261029T000000Z
DTEND:20261030T000000Z
ORGANIZER:mailto:alice@palm.test
ATTENDEE:mailto:bob@palm.test
END:VFREEBUSY
END:VCALENDAR
"""
outbox = alice.principal().schedule_outbox()
r = alice.post(str(outbox.url), FB, {"Content-Type": "text/calendar; charset=utf-8"})
check("2.0;Success" in r.raw and "FREEBUSY;" not in r.raw, "free/busy before opting in: success, no busy time")
bob.proppatch(str(b_cal.url), OPT % "true")
r = alice.post(str(outbox.url), FB, {"Content-Type": "text/calendar; charset=utf-8"})
check("FREEBUSY;FBTYPE=BUSY:20261029T120000Z/20261029T133000Z" in r.raw,
      "after Bob opts in, his lunch shows as busy 12:00-13:30Z (and nothing else about it)")
check("Lunch" not in r.raw, "free/busy carries no titles")

# 7. A read-only share: Alice grants her calendar to Bob.
coll = rest("GET", "/rest/v1/dav_collections?kind=eq.calendar&slug=eq.default&select=id,identity_id"
            "&identity_id=eq." + rest("GET", "/rest/v1/identities?handle=eq.alice&select=id", token)[0]["id"], token)[0]
bob_id = rest("POST", "/rest/v1/rpc/dav_resolve_address", token, {"address": "mailto:bob@palm.test"})
rest("POST", "/rest/v1/dav_grants", token,
     {"identity_id": coll["identity_id"], "collection_id": coll["id"], "grantee_identity": bob_id, "access": "read"})
shared = [c for c in bob.principal().calendars() if c.url.path.rstrip("/").endswith("/alice~default")]
check(len(shared) == 1, "the share appears in Bob's calendar home as alice~default")
if shared:
    titles = [e.icalendar_component.get("SUMMARY") for e in shared[0].events()]
    check(any("Lunch" in str(t) for t in titles), f"Bob reads Alice's events through the share ({len(titles)} events)")
    try:
        shared[0].save_event(INVITE.replace(UID, "intruder@palm.test"))
        refused = False
    except (dav_error.AuthorizationError, dav_error.PutError):
        refused = True
    check(refused, "Bob cannot write into a read-only share")
rest("DELETE", f"/rest/v1/dav_grants?collection_id=eq.{coll['id']}", token)
gone = [c for c in bob.principal().calendars() if c.url.path.rstrip("/").endswith("/alice~default")]
check(len(gone) == 0, "after revocation the share is gone from Bob's home")

# 8. Isolation between Alice's own identities (app password scoped to alice-work).
resp = work.request(dav + "dav/calendars/alice/default/", "PROPFIND", "", {"Depth": "1"})
check(resp.status == 404, f"alice-work's app password cannot see alice's calendar (HTTP {resp.status})")
resp = work.request(dav + "dav/calendars/alice/default/x.ics", "PUT", INVITE.replace(UID, "x@palm.test"),
                    {"Content-Type": "text/calendar"})
check(resp.status in (403, 404), f"nor write into it (HTTP {resp.status})")
check(work.principal().url.path == "/dav/principals/alice-work/", "its principal is alice-work and only that")

# 9. Alice cancels: Bob's copy is marked cancelled.
a_cal.event_by_uid(UID).delete()
bob.principal().schedule_inbox().get_items()
check("STATUS:CANCELLED" in b_cal.event_by_uid(UID).data, "deleting the organizer's event cancels Bob's copy")
b_cal.event_by_uid(UID).delete()

print("all checks passed" if failures == 0 else f"{failures} FAILED")
sys.exit(1 if failures else 0)
