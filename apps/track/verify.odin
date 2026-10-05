// Verification: the tracker tells you which issues are lying.
//
// WHY THIS EXISTS. `TODO.md` is this repository's tracker today, and in one
// afternoon three of its claims were found false: a section describing work
// that had shipped two commits earlier, a standing rule quoting "44 unit
// tests" when the real number was 99, and a reproduction note asserting a
// case did not trigger a bug when measurement said otherwise. None of those
// were careless. They were true when written, and the code moved. A tracker
// whose contents drift from the code is worse than no tracker, because people
// make plans from it and the plans are wrong in a way that looks confident.
//
// So an issue may declare a command. Exit zero means it is still true;
// non-zero means it is stale, and the tracker says so, loudly, in `track
// stale` and in the window.
//
// ---------------------------------------------------------------------------
// THE THREAT MODEL, which is the interesting part of this file
// ---------------------------------------------------------------------------
//
// `verify:` is arbitrary code execution out of a data file. The data file is
// a Markdown document that travels in a git repository, merges between
// branches, arrives in pull requests from strangers, and is edited by agents.
// Anyone who can land a commit can write a line in it. Treating it as
// anything other than hostile input would be a mistake, and the mistake would
// be of the `make`-in-a-cloned-repo class: run a read-only-looking command,
// get a shell.
//
// What this program does about it, in the order the gates sit:
//
//  1. **Nothing executes without an explicit flag, per run.** `track stale`
//     reads files and prints which issues *have* a command. Only
//     `track stale --run` executes, and `--run` is not sticky, not
//     configurable, not inferable from the environment, and not implied by
//     `--yes`. There is one call site in this whole program that can reach
//     exec, and it is `verify_run` below.
//
//  2. **Never on open, never on import, never from the window.** The GUI has
//     no path to `verify_run`; it renders whatever verdict is recorded in the
//     file and labels an unrecorded one as unverified. `track import` writes
//     the `verify:` lines it finds and runs none of them.
//
//  3. **The command is printed before it runs**, to stderr, with the id and
//     the file it came from, so a transcript shows what was executed even if
//     the process never returns.
//
//  4. **Only from the resolved scope.** A command is run only for an issue
//     loaded out of the scope directory this invocation resolved — never
//     from a path handed in on the command line, because "verify this file"
//     is a phishing primitive.
//
//  5. **The project's own denylist still applies.** The command line is split
//     on shell operators and each segment is put through `kit.cli_forbidden`,
//     the same list that stops any application here taking the machine off
//     the network, powering it down, or opening the camera. A verify command
//     that reaches for those is refused and reported, not run.
//
//  6. **A timeout.** `timeout(1)` wraps the command when it is available, so
//     a verify that waits forever fails the issue instead of hanging the
//     tracker.
//
//  7. **An off switch that cannot be overridden.** `PALM_TRACK_NO_VERIFY=1`
//     refuses every execution regardless of flags, for a machine or a CI job
//     where this feature should simply not exist.
//
// WHAT THIS IS NOT. It is not a sandbox. Gate 5 is a denylist, and a denylist
// is a speed bump, not a boundary: `sh -c 'curl … | sh'` passes it. The
// security property this program actually offers is the first gate — that no
// command in a data file runs unless a person typed `--run` on that
// invocation, having been shown the commands by the invocation before it.
// Everything else is defence in depth behind that. If you need a boundary,
// run `track stale --run` somewhere you would be willing to run `make`.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

// VERIFY_TIMEOUT is how long a command gets. Chosen so a `grep` over the tree
// or a small `odin build` finishes and a `read` from a terminal does not.
VERIFY_TIMEOUT :: 60

Verify_Result :: struct {
	id:      string,
	command: string,
	verdict: Verdict,
	code:    int,
	ran:     bool,
	refused: string, // why it was not run, when it was not
	output:  string, // the first few lines of what it said, for the report
}

// verify_disabled is the override that beats every flag.
verify_disabled :: proc() -> bool {
	v := os.get_env("PALM_TRACK_NO_VERIFY", context.temp_allocator)
	return v == "1" || v == "true" || v == "yes"
}

// verify_segments splits a command line at the shell operators that start a
// new command, so each piece can be checked on its own. `a && b | c; d` is
// four commands and all four are somebody's business.
//
// This is a splitter for a safety check, not a shell parser: it deliberately
// over-splits rather than under-splits, and it does not try to be right about
// quoting, because a check that misses a segment is worse than one that
// checks a fragment twice.
verify_segments :: proc(cmd: string, allocator := context.temp_allocator) -> [][]string {
	out := make([dynamic][]string, allocator)
	cur := make([dynamic]string, allocator)
	word := strings.builder_make(allocator)
	quote: u8 = 0
	have := false

	flush_word :: proc(cur: ^[dynamic]string, word: ^strings.Builder, have: ^bool, al: int) {
		if have^ {
			append(cur, strings.clone(strings.to_string(word^), context.temp_allocator))
			strings.builder_reset(word)
			have^ = false
		}
	}
	flush_cmd :: proc(out: ^[dynamic][]string, cur: ^[dynamic]string) {
		if len(cur) > 0 {
			seg := make([]string, len(cur), context.temp_allocator)
			copy(seg, cur[:])
			append(out, seg)
			clear(cur)
		}
	}

	i := 0
	for i < len(cmd) {
		c := cmd[i]
		if quote != 0 {
			if c == quote {
				quote = 0
			} else {
				strings.write_byte(&word, c)
			}
			have = true
			i += 1
			continue
		}
		switch c {
		case '\'', '"':
			quote = c
			have = true
			i += 1
		case ' ', '\t', '\n', '\r':
			flush_word(&cur, &word, &have, 0)
			i += 1
		case ';', '|', '&':
			flush_word(&cur, &word, &have, 0)
			flush_cmd(&out, &cur)
			i += 1
		case '`':
			// A backtick opens a command substitution; treat what follows as
			// a fresh command so its first word is checked too.
			flush_word(&cur, &word, &have, 0)
			flush_cmd(&out, &cur)
			i += 1
		case '$':
			if i + 1 < len(cmd) && cmd[i + 1] == '(' {
				flush_word(&cur, &word, &have, 0)
				flush_cmd(&out, &cur)
				i += 2
				continue
			}
			strings.write_byte(&word, c)
			have = true
			i += 1
		case '(', ')', '{', '}':
			flush_word(&cur, &word, &have, 0)
			flush_cmd(&out, &cur)
			i += 1
		case '!':
			// A leading `!` is negation, not a command. `! grep -q x f` is the
			// canonical shape of a verify, so drop it and keep checking.
			if !have && len(cur) == 0 {
				i += 1
				continue
			}
			strings.write_byte(&word, c)
			have = true
			i += 1
		case:
			strings.write_byte(&word, c)
			have = true
			i += 1
		}
	}
	flush_word(&cur, &word, &have, 0)
	flush_cmd(&out, &cur)
	return out[:]
}

// verify_forbidden puts every segment through the kit's denylist. Gate 5.
verify_forbidden :: proc(cmd: string) -> (why: string) {
	for seg in verify_segments(cmd) {
		if len(seg) == 0 {
			continue
		}
		// Strip leading VAR=value assignments, which are not the command.
		argv := seg
		for len(argv) > 0 {
			eq := strings.index_byte(argv[0], '=')
			if eq > 0 && !strings.contains(argv[0][:eq], "/") {
				argv = argv[1:]
				continue
			}
			break
		}
		if len(argv) == 0 {
			continue
		}
		if w := kit.cli_forbidden(argv); w != "" {
			return fmt.tprintf("%s: %s", argv[0], w)
		}
		// sudo is never run by anything here, and a verify command is not the
		// exception. The kit's list covers what sudo would be used *for*;
		// this covers sudo itself, because a password prompt in the middle of
		// a batch of verifications is its own hazard.
		exe := argv[0]
		if sl := strings.last_index_byte(exe, '/'); sl >= 0 {
			exe = exe[sl + 1:]
		}
		switch exe {
		case "sudo", "doas", "pkexec", "su":
			return fmt.tprintf("%s: a verification never escalates privilege", exe)
		}
	}
	return ""
}

// verify_describe is what `track stale` prints without `--run`: the command,
// and whether it would be refused if you did pass `--run`. Reading this is
// the step that makes `--run` an informed decision rather than a reflex.
verify_describe :: proc(it: ^Issue) -> (command: string, refused: string) {
	if it.verify == "" {
		return "", ""
	}
	return it.verify, verify_forbidden(it.verify)
}

// verify_run is the only place in this program that can reach exec.
//
// `allowed` is the `--run` flag, passed in rather than read from anywhere, so
// that the gate is visible at the call site and a future caller cannot
// acquire the capability by forgetting to look.
verify_run :: proc(it: ^Issue, cwd: string, allowed: bool) -> Verify_Result {
	r := Verify_Result {
		id      = it.id,
		command = it.verify,
		verdict = it.verdict,
	}
	if it.verify == "" {
		r.verdict = .Unverified
		r.refused = "no verification declared"
		return r
	}
	// Gate 1. Without the flag this returns before anything is spawned, and
	// the verdict is whatever the file already said — not a fresh one.
	if !allowed {
		r.refused = "not run: --run was not given"
		return r
	}
	// Gate 7.
	if verify_disabled() {
		r.refused = "not run: PALM_TRACK_NO_VERIFY is set"
		return r
	}
	// Gate 5.
	if why := verify_forbidden(it.verify); why != "" {
		r.refused = fmt.tprintf("refused: %s", why)
		fmt.eprintfln("[track] REFUSED, not executed: %s   (%s)", it.verify, why)
		return r
	}

	// Gate 3: shown before it is run, with where it came from, so a hung or
	// fatal command still leaves a record of what was executed.
	fmt.eprintfln("[track] %s: running verification from %s", it.id, it.path)
	fmt.eprintfln("[track]   $ %s", it.verify)

	// Gate 6. `timeout` is coreutils and effectively always here, but a
	// missing one must not silently drop the limit, so its absence is said
	// out loud.
	argv: []string
	if have_timeout() {
		argv = {"timeout", "-k", "2", fmt.tprintf("%d", VERIFY_TIMEOUT), "sh", "-c", it.verify}
	} else {
		fmt.eprintfln("[track]   (timeout(1) not found; running without a time limit)")
		argv = {"sh", "-c", it.verify}
	}

	state, sout, serr, err := os.process_exec(
		{command = argv, working_dir = cwd},
		context.temp_allocator,
	)
	r.ran = true
	if err != nil {
		r.verdict = .Stale
		r.code = -1
		r.output = fmt.tprintf("could not run: %v", err)
		return r
	}
	r.code = state.exit_code
	r.verdict = state.exit_code == 0 ? Verdict.True : Verdict.Stale
	text := strings.trim_space(string(sout))
	if text == "" {
		text = strings.trim_space(string(serr))
	}
	r.output = strings.clone(first_lines(text, 3), context.temp_allocator)
	return r
}

@(private = "file")
g_timeout_checked: bool
@(private = "file")
g_timeout_present: bool

have_timeout :: proc() -> bool {
	if !g_timeout_checked {
		g_timeout_checked = true
		g_timeout_present =
			os.exists("/usr/bin/timeout") ||
			os.exists("/bin/timeout") ||
			os.exists("/usr/local/bin/timeout")
	}
	return g_timeout_present
}

first_lines :: proc(s: string, n: int, allocator := context.temp_allocator) -> string {
	count := 0
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			count += 1
			if count == n {
				return strings.clone(s[:i], allocator)
			}
		}
	}
	if len(s) > 400 {
		return strings.clone(s[:400], allocator)
	}
	return strings.clone(s, allocator)
}

// verify_apply records a fresh verdict on the issue. The verdict lives in the
// file rather than in a cache, which is the same decision as everything else
// here: `git log -p` on an issue then shows the day it went stale, and
// `grep -l 'verified: stale'` is the whole query language.
verify_apply :: proc(it: ^Issue, r: Verify_Result) {
	if !r.ran {
		return
	}
	it.verdict = r.verdict
	it.checked = now_stamp(context.allocator)
	it.updated = strings.clone(it.checked)
}
