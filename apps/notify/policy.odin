// Quiet: an identity's notification policy, said in words.
//
// cloud/docs/product.md §8 asks for a policy per identity "written as a
// sentence", shown as that sentence in Home's rail and in the shell, so that
// nobody has to open a settings page to learn what will happen. So the
// sentence is the interface and the struct is how it is kept: `policy_parse`
// reads a sentence into a Policy, `policy_sentence` writes one back, and the
// two round-trip (the self-test asserts it). Anything the parser does not
// understand is refused with the clause it stopped at, never guessed.
//
// The grammar, clause by clause (case does not matter; clauses are separated
// by "." ";" or ","):
//
//	Quiet after 18:00                 quiet hours, 18:00 until 08:00
//	Quiet after 18:00 until 07:30     ... with the morning said
//	Quiet 22:00-07:00 / from 22:00 to 07:00 / between 22:00 and 07:00
//	Quiet until 14:00 / Quiet for 2 hours / Quiet (until 08:00)    one-off
//	Do not disturb / Focus [until 15:00 | for 45 minutes]          one-off, stricter
//	People only                       only people interrupt; reminders wait
//	Daily digest at 17:00             machines' notifications, batched
//	Calls break through / Alarms break through / Reminders wait
//	Nothing breaks through            not even reminders
//	Forge in the digest / Mute Chromium / Chat always              per app
//	Everything / Default              the product default, below
//
// `notify quiet set "after 18:00"` takes the clause without its leading
// "Quiet", because that is how the command reads.
//
// The default (no sentence): people and reminders interrupt, machines go to
// the center silently, and nothing breaks through do-not-disturb.
package main

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

Break :: enum u8 {
	Calls, // an incoming call
	Alarms, // a critical time notification
	Reminders, // any other time notification (quiet hours only; never DND)
}

App_Mode :: enum u8 {
	Default,
	Muted, // never interrupts, never in a digest: the center only
	Digest, // always batched into the digest
	Always, // interrupts unless do-not-disturb
}

App_Rule :: struct {
	app:  string,
	mode: App_Mode,
}

MORNING :: 8 * 60 // the default end of "Quiet after HH:MM"

Policy :: struct {
	identity:    string, // a handle; "*" is the default for everything else
	quiet_from:  int, // minute of the day; -1 when there are no quiet hours
	quiet_to:    int,
	quiet_until: i64, // unix ms; a one-off quiet, 0 when none
	awake_until: i64, // unix ms; quiet hours set aside until then ("Not quiet until 08:00")
	dnd_until:   i64, // unix ms; -1 until turned off, 0 when not in DND
	people_only: bool,
	digest_at:   int, // minute of the day; -1 when there is no daily digest
	breaks:      bit_set[Break],
	apps:        [dynamic]App_Rule,
}

DEFAULT_BREAKS :: bit_set[Break]{.Reminders}

policy_default :: proc(identity: string) -> Policy {
	return Policy {
		identity = identity,
		quiet_from = -1,
		quiet_to = -1,
		digest_at = -1,
		breaks = DEFAULT_BREAKS,
	}
}

policy_free :: proc(p: ^Policy) {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	delete(p.identity)
	for r in p.apps {
		delete(r.app)
	}
	delete(p.apps)
	p^ = {}
}

policy_clone :: proc(p: Policy) -> Policy {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	out := p
	out.identity = strings.clone(p.identity)
	out.apps = make([dynamic]App_Rule)
	for r in p.apps {
		append(&out.apps, App_Rule{strings.clone(r.app), r.mode})
	}
	return out
}

policy_for :: proc(s: ^Store, identity: string) -> Policy {
	for p in s.policies {
		if p.identity == identity {
			return p
		}
	}
	for p in s.policies {
		if p.identity == "*" {
			return p
		}
	}
	return policy_default(identity)
}

// policy_put replaces (or adds) the stored policy for p.identity, taking
// ownership of p.
policy_put :: proc(s: ^Store, p: Policy) {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	for &q in s.policies {
		if q.identity == p.identity {
			policy_free(&q)
			q = p
			touch(s)
			return
		}
	}
	append(&s.policies, p)
	touch(s)
}

// ---------------------------------------------------------------------------
// Time of day
// ---------------------------------------------------------------------------

DAY_MS :: i64(86_400_000)

// local_minute is the minute of the local day at `now`.
local_minute :: proc(now, tz_offset: i64) -> int {
	t := now + tz_offset * 1000
	m := ((t % DAY_MS) + DAY_MS) % DAY_MS
	return int(m / 60_000)
}

local_day :: proc(now, tz_offset: i64) -> int {
	t := now + tz_offset * 1000
	return int((t - (((t % DAY_MS) + DAY_MS) % DAY_MS)) / DAY_MS)
}

// next_at is the next instant (strictly after now) whose local minute is `m`.
next_at :: proc(now, tz_offset: i64, m: int) -> i64 {
	t := now + tz_offset * 1000
	day_start := t - (((t % DAY_MS) + DAY_MS) % DAY_MS)
	at := day_start + i64(m) * 60_000
	if at <= t {
		at += DAY_MS
	}
	return at - tz_offset * 1000
}

in_window :: proc(m, from, to: int) -> bool {
	if from < 0 || to < 0 || from == to {
		return false
	}
	if from < to {
		return m >= from && m < to
	}
	return m >= from || m < to
}

hhmm :: proc(m: int) -> string {
	return fmt.tprintf("%02d:%02d", m / 60, m % 60)
}

// in_hours: inside the quiet hours, and they have not been set aside.
in_hours :: proc(p: Policy, now, tz_offset: i64) -> bool {
	return p.awake_until <= now && in_window(local_minute(now, tz_offset), p.quiet_from, p.quiet_to)
}

// Hold is why an identity is not being interrupted right now.
Hold :: enum u8 {
	None,
	Quiet, // quiet hours, or a one-off quiet
	Dnd, // do-not-disturb: the identity's own, or the whole person's
}

hold_of :: proc(p: Policy, global_dnd: bool, now, tz_offset: i64) -> Hold {
	if global_dnd || p.dnd_until == -1 || p.dnd_until > now {
		return .Dnd
	}
	if p.quiet_until > now || in_hours(p, now, tz_offset) {
		return .Quiet
	}
	return .None
}

// hold_ends is when the current hold lifts, or 0 when it is open-ended
// (do-not-disturb until turned off) or there is none.
hold_ends :: proc(p: Policy, global_dnd: bool, global_until, now, tz_offset: i64) -> i64 {
	switch hold_of(p, global_dnd, now, tz_offset) {
	case .None:
		return 0
	case .Dnd:
		if global_dnd {
			return global_until
		}
		return p.dnd_until > 0 ? p.dnd_until : 0
	case .Quiet:
		end := i64(0)
		if p.quiet_until > now {
			end = p.quiet_until
		}
		if in_hours(p, now, tz_offset) {
			e := next_at(now, tz_offset, p.quiet_to)
			if e > end {
				end = e
			}
		}
		return end
	}
	return 0
}

// ---------------------------------------------------------------------------
// The decision
// ---------------------------------------------------------------------------

Decision :: struct {
	delivery: Delivery,
	sound:    bool,
	why:      string, // temp allocated
	daily:    bool, // a Digest that waits for the daily time, not for a hold to lift
}

dec :: proc(d: Delivery, sound: bool, why: string, daily := false) -> Decision {
	return Decision{delivery = d, sound = sound, why = why, daily = daily}
}

// cut_prefix is `s` without `prefix`, and whether it had it.
cut_prefix :: proc(s, prefix: string) -> (string, bool) {
	if strings.has_prefix(s, prefix) {
		return s[len(prefix):], true
	}
	return s, false
}

app_mode :: proc(p: Policy, app: string) -> App_Mode {
	for r in p.apps {
		if strings.equal_fold(r.app, app) {
			return r.mode
		}
	}
	return .Default
}

ident_label :: proc(handle: string) -> string {
	if handle == "" || handle == "*" {
		return "This device"
	}
	return identity_name(handle)
}

// decide is the whole policy, in one place, in the order a person would
// explain it. Every outcome carries the sentence that caused it, so the
// center can say *why* something did not interrupt.
decide :: proc(p: Policy, global_dnd: bool, n: ^Note, now, tz_offset: i64) -> Decision {
	who := ident_label(n.identity)
	mode := app_mode(p, n.app)
	call := is_call(n)
	alarm := is_alarm(n)

	if mode == .Muted {
		return dec(.Center, false, fmt.tprintf("%s is muted for %s", app_label(n.app), who))
	}

	switch hold_of(p, global_dnd, now, tz_offset) {
	case .Dnd:
		if call && .Calls in p.breaks {
			return dec(.Toast, true, "A call breaks through do not disturb")
		}
		if alarm && .Alarms in p.breaks {
			return dec(.Toast, true, "An alarm breaks through do not disturb")
		}
		return dec(.Digest, false, global_dnd ? "Do not disturb is on" : fmt.tprintf("%s is on do not disturb", who))
	case .Quiet:
		if call {
			if .Calls in p.breaks {
				return dec(.Toast, true, fmt.tprintf("%s is quiet; calls break through", who))
			}
			return dec(.Digest, false, fmt.tprintf("%s is quiet; calls wait", who))
		}
		if alarm && (.Alarms in p.breaks || .Reminders in p.breaks) {
			return dec(.Toast, true, fmt.tprintf("%s is quiet; alarms break through", who))
		}
		if n.class == .Time && !alarm && .Reminders in p.breaks && !p.people_only {
			return dec(.Toast, true, fmt.tprintf("%s is quiet; reminders break through", who))
		}
		return dec(.Digest, false, fmt.tprintf("%s is quiet", who))
	case .None:
	}

	if n.urgency == .Low && mode != .Always {
		return dec(.Center, false, "Low priority")
	}
	if mode == .Digest {
		if p.digest_at >= 0 {
			return dec(.Digest, false, fmt.tprintf("%s goes in the %s digest", app_label(n.app), hhmm(p.digest_at)), true)
		}
		return dec(.Center, false, fmt.tprintf("%s goes in the digest", app_label(n.app)))
	}
	if mode == .Always {
		return dec(.Toast, n.urgency != .Low, fmt.tprintf("%s always interrupts", app_label(n.app)))
	}

	switch n.class {
	case .Person:
		return dec(.Toast, true, "From a person")
	case .Time:
		if p.people_only && !alarm {
			return dec(.Center, false, fmt.tprintf("%s: people only", who))
		}
		return dec(.Toast, true, "At its time")
	case .Machine:
		if p.digest_at >= 0 {
			return dec(.Digest, false, fmt.tprintf("Machines go in the %s digest", hhmm(p.digest_at)), true)
		}
		return dec(.Center, false, "Machines never interrupt")
	}
	return dec(.Center, false, "")
}

// ---------------------------------------------------------------------------
// The sentence
// ---------------------------------------------------------------------------

// policy_sentence writes the policy as the sentence a person reads. The
// default policy is said positively rather than as an empty string.
policy_sentence :: proc(p: Policy, now: i64, tz_offset: i64, allocator := context.temp_allocator) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if p.dnd_until == -1 {
		append(&parts, "Do not disturb")
	} else if p.dnd_until > now {
		append(&parts, fmt.tprintf("Do not disturb until %s", hhmm(local_minute(p.dnd_until, tz_offset))))
	}
	if p.quiet_from >= 0 {
		if p.quiet_to == MORNING {
			append(&parts, fmt.tprintf("Quiet after %s", hhmm(p.quiet_from)))
		} else {
			append(&parts, fmt.tprintf("Quiet %s–%s", hhmm(p.quiet_from), hhmm(p.quiet_to)))
		}
	}
	if p.quiet_until > now {
		append(&parts, fmt.tprintf("Quiet until %s", hhmm(local_minute(p.quiet_until, tz_offset))))
	}
	if p.awake_until > now && p.quiet_from >= 0 {
		append(&parts, fmt.tprintf("Not quiet until %s", hhmm(local_minute(p.awake_until, tz_offset))))
	}
	if p.people_only {
		append(&parts, "People only")
	}
	if p.digest_at >= 0 {
		append(&parts, fmt.tprintf("Daily digest at %s", hhmm(p.digest_at)))
	}
	switch {
	case p.breaks == {}:
		append(&parts, "Nothing breaks through")
	case p.breaks != DEFAULT_BREAKS:
		names := make([dynamic]string, context.temp_allocator)
		if .Calls in p.breaks {
			append(&names, "Calls")
		}
		if .Alarms in p.breaks {
			append(&names, len(names) == 0 ? "Alarms" : "alarms")
		}
		if len(names) > 0 {
			append(&parts, fmt.tprintf("%s break through", strings.join(names[:], " and ", context.temp_allocator)))
		}
		if .Reminders not_in p.breaks {
			append(&parts, "Reminders wait")
		}
	}
	for r in p.apps {
		switch r.mode {
		case .Muted:
			append(&parts, fmt.tprintf("Mute %s", app_label(r.app)))
		case .Digest:
			append(&parts, fmt.tprintf("%s in the digest", app_label(r.app)))
		case .Always:
			append(&parts, fmt.tprintf("%s always", app_label(r.app)))
		case .Default:
		}
	}
	if len(parts) == 0 {
		return strings.clone("People and reminders", allocator)
	}
	return strings.join(parts[:], ". ", allocator)
}

// parse_time reads "18:00", "18h", "18", "6pm", "6:30 pm", "noon",
// "midnight" into a minute of the day.
parse_time :: proc(s: string) -> (m: int, ok: bool) {
	t := strings.trim_space(strings.to_lower(s, context.temp_allocator))
	switch t {
	case "noon", "midday":
		return 12 * 60, true
	case "midnight":
		return 0, true
	case "morning":
		return MORNING, true
	}
	pm, am := false, false
	if strings.has_suffix(t, "pm") {
		pm = true
		t = strings.trim_space(t[:len(t) - 2])
	} else if strings.has_suffix(t, "am") {
		am = true
		t = strings.trim_space(t[:len(t) - 2])
	}
	t = strings.trim_suffix(t, "h")
	h, mi := 0, 0
	if i := strings.index_any(t, ":h"); i >= 0 {
		hv, ok1 := strconv.parse_int(t[:i])
		mv, ok2 := strconv.parse_int(t[i + 1:])
		if !ok1 || !ok2 || len(t[i + 1:]) != 2 {
			return 0, false
		}
		h, mi = hv, mv
	} else {
		hv, ok1 := strconv.parse_int(t)
		if !ok1 || len(t) == 0 || len(t) > 2 {
			return 0, false
		}
		h = hv
	}
	if pm || am {
		if h < 1 || h > 12 {
			return 0, false
		}
		if h == 12 {
			h = 0
		}
		if pm {
			h += 12
		}
	}
	if h < 0 || h > 23 || mi < 0 || mi > 59 {
		return 0, false
	}
	return h * 60 + mi, true
}

// parse_duration reads "2 hours", "45 minutes", "45 min", "1h", "90m".
parse_duration :: proc(s: string) -> (ms: i64, ok: bool) {
	t := strings.trim_space(strings.to_lower(s, context.temp_allocator))
	t = strings.trim_prefix(t, "an ")
	t = strings.trim_prefix(t, "a ")
	if t == "hour" {
		return 3_600_000, true
	}
	i := 0
	for i < len(t) && t[i] >= '0' && t[i] <= '9' {
		i += 1
	}
	if i == 0 {
		return 0, false
	}
	n, _ := strconv.parse_int(t[:i])
	unit := strings.trim_space(t[i:])
	switch unit {
	case "h", "hr", "hrs", "hour", "hours":
		return i64(n) * 3_600_000, n > 0
	case "m", "min", "mins", "minute", "minutes":
		return i64(n) * 60_000, n > 0
	}
	return 0, false
}

// split_range reads "18:00-07:00", "18:00–07:00", "18:00 to 07:00".
split_range :: proc(s: string) -> (a, b: string, ok: bool) {
	for sep in ([?]string{"–", "—", " to ", " and ", "-"}) {
		if i := strings.index(s, sep); i > 0 {
			return strings.trim_space(s[:i]), strings.trim_space(s[i + len(sep):]), true
		}
	}
	return "", "", false
}

Parse_Error :: struct {
	clause: string,
	hint:   string,
}

// policy_parse reads a sentence. `base` is the policy to start from: the
// default for `set`, the current one for `add`. On failure the clause that
// could not be read comes back, so the refusal can quote it.
policy_parse :: proc(sentence: string, base: Policy, now, tz_offset: i64) -> (p: Policy, err: Parse_Error, ok: bool) {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	p = policy_clone(base)
	text := strings.to_lower(strings.trim_space(sentence), context.temp_allocator)
	// "Quiet after 18:00 and a daily digest at 17:00" reads as two clauses;
	// "calls and alarms break through" and "between 22:00 and 07:00" are one.
	clauses := make([dynamic]string, context.temp_allocator)
	for piece in strings.split_multi(text, {".", ";", ",", " and a ", " and the ", " then "}, context.temp_allocator) {
		c := strings.trim_space(piece)
		if c != "" {
			append(&clauses, c)
		}
	}
	if len(clauses) == 0 {
		policy_free(&p)
		return policy_clone(policy_default(base.identity)), {}, true
	}
	for c in clauses {
		if !parse_clause(&p, c, now, tz_offset) {
			policy_free(&p)
			return {}, Parse_Error{clause = c, hint = "try “Quiet after 18:00”, “Daily digest at 17:00”, “People only”, “Calls break through” or “Forge in the digest”"}, false
		}
	}
	return p, {}, true
}

@(private = "file")
parse_clause :: proc(p: ^Policy, raw: string, now, tz_offset: i64) -> bool {
	c := raw
	switch c {
	case "everything", "default", "all", "everything interrupts", "people and reminders", "notifications on":
		apps := p.apps
		for r in apps {
			delete(r.app)
		}
		delete(apps)
		ident := p.identity
		p^ = policy_default(ident)
		return true
	case "people only", "only people", "people":
		p.people_only = true
		return true
	case "nothing breaks through", "nothing breaks in":
		p.breaks = {}
		return true
	case "reminders wait", "reminders don't break through", "reminders do not break through":
		p.breaks -= {.Reminders}
		return true
	case "resume", "end quiet", "quiet over", "not quiet now":
		// Ends a one-off quiet or this identity's do-not-disturb; quiet
		// hours stay as they are.
		p.quiet_until = 0
		p.dnd_until = 0
		if in_window(local_minute(now, tz_offset), p.quiet_from, p.quiet_to) {
			p.awake_until = next_at(now, tz_offset, p.quiet_to)
		}
		return true
	case "not quiet", "quiet off", "no quiet hours", "loud":
		p.quiet_from, p.quiet_to, p.quiet_until, p.awake_until = -1, -1, 0, 0
		return true
	case "no digest", "digest off":
		p.digest_at = -1
		return true
	case "do not disturb", "dnd", "focus", "do not disturb on":
		p.dnd_until = -1
		return true
	case "do not disturb off", "dnd off", "focus off":
		p.dnd_until = 0
		return true
	case "quiet", "quiet now", "hold", "quiet until tomorrow":
		p.quiet_until = next_at(now, tz_offset, MORNING)
		p.awake_until = 0
		return true
	}

	if strings.has_suffix(c, "break through") || strings.has_suffix(c, "breaks through") {
		what := strings.trim_space(strings.trim_suffix(strings.trim_suffix(c, "breaks through"), "break through"))
		got := false
		if strings.contains(what, "call") {
			p.breaks += {.Calls}
			got = true
		}
		if strings.contains(what, "alarm") {
			p.breaks += {.Alarms}
			got = true
		}
		if strings.contains(what, "reminder") {
			p.breaks += {.Reminders}
			got = true
		}
		return got
	}

	// Do not disturb / focus with an end.
	for lead in ([?]string{"do not disturb", "dnd", "focus"}) {
		if rest, has := cut_prefix(c, lead); has {
			rest = strings.trim_space(rest)
			if t, ok := cut_prefix(rest, "until "); ok {
				m, good := parse_time(t)
				if !good {
					return false
				}
				p.dnd_until = next_at(now, tz_offset, m)
				return true
			}
			if d, ok := cut_prefix(rest, "for "); ok {
				ms, good := parse_duration(d)
				if !good {
					return false
				}
				p.dnd_until = now + ms
				return true
			}
			return false
		}
	}

	// The digest.
	for lead in ([?]string{"daily digest at ", "daily digest ", "digest at ", "digest "}) {
		if t, has := cut_prefix(c, lead); has {
			m, good := parse_time(t)
			if !good {
				return false
			}
			p.digest_at = m
			return true
		}
	}

	// Quiet. `quiet set "after 18:00"` arrives without the word.
	q := c
	if rest, has := cut_prefix(c, "quiet"); has {
		q = strings.trim_space(rest)
	}
	if t, has := cut_prefix(q, "after "); has {
		from_s := t
		to := MORNING
		if i := strings.index(t, " until "); i >= 0 {
			from_s = t[:i]
			m, good := parse_time(t[i + 7:])
			if !good {
				return false
			}
			to = m
		}
		m, good := parse_time(from_s)
		if !good {
			return false
		}
		p.quiet_from, p.quiet_to = m, to
		return true
	}
	if t, has := cut_prefix(c, "not quiet until "); has {
		m, good := parse_time(t)
		if !good {
			return false
		}
		p.awake_until = next_at(now, tz_offset, m)
		p.quiet_until = 0
		return true
	}
	if t, has := cut_prefix(q, "until "); has {
		m, good := parse_time(t)
		if !good {
			return false
		}
		p.quiet_until = next_at(now, tz_offset, m)
		p.awake_until = 0
		return true
	}
	if t, has := cut_prefix(q, "for "); has {
		ms, good := parse_duration(t)
		if !good {
			return false
		}
		p.quiet_until = now + ms
		return true
	}
	for lead in ([?]string{"from ", "between ", ""}) {
		if t, has := cut_prefix(q, lead); has && t != "" {
			a, b, split := split_range(t)
			if !split {
				continue
			}
			ma, ga := parse_time(a)
			mb, gb := parse_time(b)
			if !ga || !gb || ma == mb {
				return false
			}
			p.quiet_from, p.quiet_to = ma, mb
			return true
		}
	}

	// Per application: "mute chromium", "chromium muted", "forge in the
	// digest", "chat always".
	if app, has := cut_prefix(c, "mute "); has && app != "" {
		app_rule(p, app, .Muted)
		return true
	}
	if app, has := cut_prefix(c, "always "); has && app != "" {
		app_rule(p, app, .Always)
		return true
	}
	for suffix in ([?]struct {
		s: string,
		m: App_Mode,
	}{{" in the digest", .Digest}, {" in digest", .Digest}, {" digest", .Digest}, {" muted", .Muted}, {" off", .Muted}, {" always", .Always}, {" as usual", .Default}}) {
		if strings.has_suffix(c, suffix.s) {
			app := strings.trim_space(c[:len(c) - len(suffix.s)])
			if app == "" || strings.contains(app, " ") {
				return false
			}
			app_rule(p, app, suffix.m)
			return true
		}
	}
	return false
}

@(private = "file")
app_rule :: proc(p: ^Policy, app: string, mode: App_Mode) {
	name := app_key(app)
	for &r, i in p.apps {
		if r.app == name {
			if mode == .Default {
				delete(r.app)
				ordered_remove(&p.apps, i)
			} else {
				r.mode = mode
			}
			return
		}
	}
	if mode != .Default {
		append(&p.apps, App_Rule{strings.clone(name), mode})
	}
}

// app_key is the stored spelling of an application named in a sentence:
// "Updates" is palm, "Software" is the store, otherwise the lowercase name.
app_key :: proc(name: string) -> string {
	n := strings.to_lower(strings.trim_space(name), context.temp_allocator)
	switch n {
	case "updates", "update":
		return "palm"
	case "software":
		return "store"
	case "notifications":
		return "notify"
	}
	return n
}
