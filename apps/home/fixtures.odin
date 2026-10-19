// FIXTURES. Every name, address, company, message and file below is
// invented for the prototype and for its screenshots. None of it is read
// from the machine, the account or the network, and nothing here should be
// mistaken for a sample of anybody's real data.
//
// The persona: Camille, one Palmy account, four identities — a personal
// self, a job at an invented co-operative called Northwind, a public face for
// talks and shopping, and an open-source side project called Halcyon. It is
// Monday 19 October, 09:40.
package main

fixtures_load :: proc() -> Store {
	s := Store {
		source  = .Fixtures,
		owner   = "Camille Roux",
		now_day = "Monday 19 October",
		now_min = 9 * 60 + 40,
		synced  = "Synced 2 min ago",
	}

	append(
		&s.identities,
		Identity{id = "fx-personal", handle = "camille", name = "Personal", address = "camille@palm.test", kind = .Personal, color = "teal"},
		Identity{id = "fx-work", handle = "camille.roux", name = "Northwind", address = "camille.roux@northwind.coop", kind = .Work, color = "blue", quiet = "Quiet after 18:00"},
		Identity{id = "fx-public", handle = "hello", name = "Public", address = "hello@camille.studio", kind = .Public, color = "amber", quiet = "Daily digest at 17:00"},
		Identity{id = "fx-halcyon", handle = "camille.h", name = "Halcyon", address = "camille@halcyon.dev", kind = .Project, color = "violet"},
	)

	P :: 0
	W :: 1
	U :: 2
	H :: 3

	add :: proc(s: ^Store, it: Item) {
		append(&s.items, it)
	}

	// Today's agenda, across all four identities.
	add(&s, {kind = .Event, ident = P, title = "Run along the canal", detail = "Quai de Valmy", day = 0, at = 7*60 + 30, mins = 40})
	add(&s, {kind = .Event, ident = W, title = "Weekly design review", detail = "Room 2 · video link", who = "Priya Shah", day = 0, at = 10*60, mins = 45})
	add(&s, {kind = .Event, ident = P, title = "Lunch with Théo", detail = "Le Comptoir", day = 0, at = 12*60 + 30, mins = 60})
	add(&s, {kind = .Event, ident = W, title = "Lumen Health: contract call", detail = "Video · Jonas, Priya, Lumen legal", who = "Jonas Weber", day = 0, at = 14*60, mins = 60})
	add(&s, {kind = .Event, ident = H, title = "Halcyon contributor sync", detail = "Video · 6 people", who = "Mei Tanaka", day = 0, at = 16*60 + 30, mins = 30})
	add(&s, {kind = .Event, ident = P, title = "Dentist", detail = "Dr Martin, rue Oberkampf", day = 0, at = 18*60 + 15, mins = 30})
	add(&s, {kind = .Event, ident = W, title = "Roadmap review with the board", detail = "Boardroom", who = "Priya Shah", day = 2, at = 11*60, mins = 90})
	add(&s, {kind = .Event, ident = U, title = "Paris Web: speaker rehearsal", detail = "Online", day = 4, at = 17*60, mins = 30})

	// Threads a person is waiting on.
	add(&s, {kind = .Mail, ident = W, title = "Q4 roadmap: need your sign-off by Wednesday", who = "Priya Shah", detail = "I've folded in the Lumen numbers. The only open question is whether offline drafts ship in Q4 or slip…", day = 0, at = 9*60 + 14, unread = true, waiting = true})
	add(&s, {kind = .Mail, ident = P, title = "Flat viewing on Saturday?", who = "Ines Roux", detail = "The agency can do 11:00 or 15:30. Mum says she can come for the second one if you want a…", day = 0, at = 8*60 + 2, unread = true, waiting = true})
	add(&s, {kind = .Mail, ident = H, title = "Translators for v0.4", who = "Mei Tanaka", detail = "We have Japanese and German covered. Could you ask on the forum about Arabic? Right-to-left…", day = 0, at = 7*60 + 48, unread = true, waiting = true})
	add(&s, {kind = .Mail, ident = W, title = "Re: Lumen Health contract redlines", who = "Jonas Weber", detail = "Clause 9 is back to their wording. I'd push on the data-residency annex before the call…", day = -1, at = 18*60 + 20, waiting = true})
	add(&s, {kind = .Mail, ident = U, title = "Your talk was accepted: Paris Web 2026", who = "Paris Web programme", detail = "Congratulations! Please confirm your slot and send a short bio and photo by 2 November…", day = -1, at = 16*60 + 5, unread = true, waiting = true})

	// Mail that is only there to be found.
	add(&s, {kind = .Mail, ident = W, title = "Roadmap draft v3 (spreadsheet attached)", who = "Priya Shah", detail = "Changes from v2 are highlighted in yellow.", day = -4, at = 15*60})
	add(&s, {kind = .Mail, ident = P, title = "Your train tickets: Paris → Lyon", who = "SNCF Connect", detail = "Friday 23 October, 08:04, coach 14 seat 62.", day = -2, at = 21*60})
	add(&s, {kind = .Mail, ident = U, title = "Order shipped: mechanical keyboard", who = "Clavier & Co", detail = "Tracking number and delivery window inside.", day = -3, at = 10*60})
	add(&s, {kind = .Mail, ident = H, title = "Sponsorship: roadmap questions from Lumen Health", who = "Open Collective", detail = "A sponsor asked whether offline sync is on the public roadmap.", day = -6, at = 9*60})

	// Files and documents.
	add(&s, {kind = .Doc, ident = W, title = "Q4 Roadmap", app = "Sheets", who = "You", detail = "Northwind / Planning", day = 0, at = 9*60 + 22, recent = true})
	add(&s, {kind = .Doc, ident = W, title = "Lumen Health contract v7", app = "Docs", who = "Jonas Weber", detail = "Northwind / Legal / Lumen", day = 0, at = 8*60 + 41, recent = true})
	add(&s, {kind = .Doc, ident = H, title = "v0.4 release notes", app = "Docs", who = "Mei Tanaka", detail = "Halcyon / Releases", day = -1, at = 22*60 + 10, recent = true})
	add(&s, {kind = .Doc, ident = U, title = "Paris Web talk: Software you can see the bottom of", app = "Slides", who = "You", detail = "Talks / 2026", day = -1, at = 17*60, recent = true})
	add(&s, {kind = .Doc, ident = P, title = "Apartment budget", app = "Sheets", who = "You", detail = "Home / Moving", day = -2, at = 20*60, recent = true})
	add(&s, {kind = .Doc, ident = H, title = "Halcyon public roadmap", app = "Docs", who = "Mei Tanaka", detail = "Halcyon / Planning", day = -9, at = 11*60})
	add(&s, {kind = .File, ident = P, title = "Passport scan.pdf", app = "Files", who = "You", detail = "Documents / ID", day = -12, at = 9*60})
	add(&s, {kind = .File, ident = W, title = "Roadmap offsite photos.zip", app = "Files", who = "Priya Shah", detail = "Northwind / Offsite 2026", day = -20, at = 9*60})

	// Tasks.
	add(&s, {kind = .Task, ident = W, title = "Sign off the Q4 roadmap", detail = "Due today", day = 0, at = 17 * 60})
	add(&s, {kind = .Task, ident = P, title = "Renew passport", detail = "Overdue by 2 days", day = -2, at = 12 * 60})
	add(&s, {kind = .Task, ident = H, title = "Review PR #212: offline drafts", detail = "Due today", day = 0, at = 18 * 60})
	add(&s, {kind = .Task, ident = U, title = "Send bio and photo to Paris Web", detail = "Due 2 Nov", day = 14, at = 12 * 60})
	add(&s, {kind = .Task, ident = P, title = "Book train to Lyon", detail = "Done this morning", day = 0, at = 8 * 60, done = true})

	// Chat and people, so search has them too.
	add(&s, {kind = .Chat, ident = W, title = "#design", who = "Priya Shah", detail = "Roadmap slide 4 still says Q3, fixing now", day = 0, at = 9*60 + 31})
	add(&s, {kind = .Chat, ident = H, title = "#contributors", who = "Mei Tanaka", detail = "Offline drafts PR is ready for review", day = 0, at = 8*60 + 55})
	add(&s, {kind = .Person, ident = W, title = "Priya Shah", detail = "Head of product, Northwind"})
	add(&s, {kind = .Person, ident = W, title = "Jonas Weber", detail = "Legal, Northwind"})
	add(&s, {kind = .Person, ident = P, title = "Ines Roux", detail = "Sister"})
	add(&s, {kind = .Person, ident = H, title = "Mei Tanaka", detail = "Maintainer, Halcyon"})

	return s
}
