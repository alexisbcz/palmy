// The model Home draws from, and the one seam where its data arrives.
//
// Home owns no data. Mail lives in mailcore's Maildir and the cloud mail
// tables, files in drive, events in calendar, and Home only reads the
// *index* of them: a flat list of Items, each carrying the identity it
// belongs to, from which it draws Today and search. The seam is one
// procedure, `store_load`, returning identities and items:
//
//	.Device     the default: the local search index palm-indexd keeps, one
//	            per identity (apps/index; device.odin). Works with no
//	            network and no account: local-only mode is the same path
//	.Fixtures   fixtures.odin, invented, deterministic, for screenshots and
//	            the self-test (`home --fixtures`, PALM_HOME_FIXTURES=1)
//
// There is no .Cloud source on purpose: Home reads the device, and the
// cloud is where the device converges (product.md P5).
//
// Whatever the source, the rule Home is held to is the contract's: an item
// belongs to exactly one identity and is drawn labelled with it.
package main

import "core:strings"

Identity_Kind :: enum {
	Personal,
	Work,
	Public,
	Project,
}

// Identity mirrors a row of public.identities, plus the address mail goes
// out from and the notification policy Home shows next to it.
Identity :: struct {
	id:      string, // public.identities.id; a slug for fixtures
	handle:  string,
	name:    string, // display_name
	address: string, // the From: line this identity sends as
	kind:    Identity_Kind,
	color:   string, // public.identities.color, a palette name
	quiet:   string, // "" when notifications flow, else why they are held
}

Kind :: enum {
	Mail,
	Event,
	Task,
	Doc,
	File,
	Note,
	Chat,
	Person,
	Page,
	Issue,
}

// Item is anything Today or search can show. Fields not meaningful for a
// kind stay zero.
Item :: struct {
	kind:    Kind,
	ident:   int, // index into Store.identities
	title:   string, // subject, file name, event title, task text, name
	detail:  string, // snippet, folder path, place, role
	who:     string, // sender, last editor, organiser
	app:     string, // the application that opens it: "Mail", "Sheets", ...
	day:     int, // days from today; 0 today, -1 yesterday
	at:      int, // minute of the day (events, due times, last activity)
	mins:    int, // event duration
	unread:  bool,
	waiting: bool, // a person is waiting on you: shown under "Waiting on you"
	recent:  bool, // shown under "Recently opened"
	done:    bool,
	// From the index (device.odin); empty for fixtures.
	dated:   bool, // a task with a due date, as opposed to an open issue
	key:     string,
	uri:     string,
	raw_app: string, // the index's app name: docs, sheets, mail, track…
	snippet: string,
	mark:    [2]int, // the first match in snippet, {-1, -1} for none
	time:    i64,
}

Source :: enum {
	Device,
	Fixtures,
}

Store :: struct {
	source:     Source,
	owner:      string, // the person, not an identity
	identities: [dynamic]Identity,
	items:      [dynamic]Item,
	now_day:    string, // "Monday 19 October"
	now_min:    int,
	now_unix:   i64,
	synced:     string, // what the sync status line says
	daemon:     bool, // the indexer is running (device)
}

store_load :: proc(src: Source) -> Store {
	switch src {
	case .Fixtures:
		return fixtures_load()
	case .Device:
		return device_load()
	}
	return {}
}

// KIND_APP is the application each kind opens in, for the "opens in" hint.
KIND_APP := [Kind]string {
	.Mail   = "Mail",
	.Event  = "Calendar",
	.Task   = "Tasks",
	.Doc    = "Docs",
	.File   = "Files",
	.Note   = "Notes",
	.Chat   = "Chat",
	.Person = "Contacts",
	.Page   = "Browser",
	.Issue  = "Forge",
}

KIND_PLURAL := [Kind]string {
	.Mail   = "Mail",
	.Event  = "Events",
	.Task   = "Tasks",
	.Doc    = "Documents",
	.File   = "Files",
	.Note   = "Notes",
	.Chat   = "Chat",
	.Person = "People",
	.Page   = "Web",
	.Issue  = "Issues",
}

// initials of a display name: "Priya Shah" -> "PS".
initials :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	take := true
	n := 0
	for r in name {
		if r == ' ' || r == '-' {
			take = true
			continue
		}
		if take && n < 2 {
			strings.write_rune(&b, r)
			n += 1
		}
		take = false
	}
	return strings.to_upper(strings.to_string(b), context.temp_allocator)
}

clock :: proc(min: int) -> string {
	return tfmt("%02d:%02d", min / 60, min % 60)
}

// ago describes when something happened relative to now, the way a person
// says it rather than a timestamp.
ago :: proc(s: ^Store, it: Item) -> string {
	if it.day < -1 {
		return tfmt("%d days ago", -it.day)
	}
	if it.day == -1 {
		return "Yesterday"
	}
	d := s.now_min - it.at
	switch {
	case d < 1:
		return "Now"
	case d < 60:
		return tfmt("%d min", d)
	case d < 60 * 6:
		return tfmt("%d h", d / 60)
	}
	return clock(it.at)
}
