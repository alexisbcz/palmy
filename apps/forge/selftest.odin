package main

// Offline checks: the command surface (every example parses, destructive
// verbs refuse without --yes, nouns written apart are rewritten), repository
// references, the diff reader, the activity text and the syntax lexer as
// this app uses it. The end-to-end behaviour against a running stack and
// forge server is cloud/forge/demo.sh.

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import kit "kit:."

@(private = "file")
passed, failed: int

@(private = "file")
check :: proc(ok: bool, what: string, args: ..any) {
	if ok {
		passed += 1
	} else {
		failed += 1
		fmt.eprintfln("FAIL %s", fmt.tprintf(what, ..args))
	}
}

selftest :: proc() -> int {
	s := surface()

	// every example in the schema parses
	for cmd in s.commands {
		for ex in cmd.examples {
			if strings.contains(ex, "$(") {
				continue
			}
			argv := kit.cli_split_example(ex)
			if len(argv) == 0 || argv[0] != "forge" {
				check(false, "example does not start with forge: %s", ex)
				continue
			}
			args := rewrite_argv(argv[1:])
			c, code := kit.cli_bind(s, args)
			check(code == kit.EXIT_OK || code == kit.EXIT_NEEDS_YES && cmd.effect == .Destructive, "example parses: %s (exit %d)", ex, code)
			if code == kit.EXIT_OK {
				check(c.cmd != nil && c.cmd.verb == cmd.verb, "example reaches its verb: %s", ex)
			}
		}
	}

	// destructive verbs refuse without --yes, before any network
	for argv in ([?][]string{{"repo-delete", "ada/x"}, {"token-revoke", "00000000-0000-0000-0000-000000000000"}}) {
		_, code := kit.cli_bind(s, argv)
		check(code == kit.EXIT_NEEDS_YES, "%s refuses without --yes (got %d)", argv[0], code)
	}

	// nouns written apart
	{
		a := rewrite_argv({"repo", "create", "notes", "--readme"})
		check(len(a) == 3 && a[0] == "repo-create" && a[1] == "notes", "repo create -> repo-create")
		b := rewrite_argv({"pr", "merge", "ada/x", "2"})
		check(b[0] == "pr-merge" && b[2] == "2", "pr merge -> pr-merge")
		c := rewrite_argv({"repo", "--help"})
		check(c[0] == "repo" && len(c) == 2, "a flag after a noun is left alone")
		d := rewrite_argv({"tree", "ada/x"})
		check(d[0] == "tree", "a verb that is not a noun is left alone")
	}

	// repository references
	{
		r, ok := parse_repo_ref("ada/notes.git")
		check(ok && r.owner == "ada" && r.name == "notes", "owner/name.git")
		_, bad := parse_repo_ref("notes")
		check(!bad, "a bare name is refused")
		_, bad2 := parse_repo_ref("a/b/c")
		check(!bad2, "three segments are refused")
	}

	// the diff reader
	{
		text := "diff --git a/src/a.odin b/src/a.odin\n" +
			"index 1..2 100644\n--- a/src/a.odin\n+++ b/src/a.odin\n" +
			"@@ -10,4 +10,5 @@ main :: proc() {\n" +
			" \tx := 1\n-\ty := 2\n+\ty := 3\n+\tz := 4\n \treturn\n" +
			"\\ No newline at end of file\n" +
			"diff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+hello\n" +
			"diff --git a/img.png b/img.png\nBinary files a/img.png and b/img.png differ\n"
		files := parse_diff(text, context.temp_allocator)
		check(len(files) == 3, "three files (got %d)", len(files))
		if len(files) == 3 {
			f := files[0]
			check(f.new_path == "src/a.odin" && f.additions == 2 && f.deletions == 1, "counts on a modified file")
			check(len(f.lines) == 6 && f.lines[0].kind == .Hunk, "hunk header first")
			check(f.lines[1].old_no == 10 && f.lines[1].new_no == 10, "context numbered on both sides")
			check(f.lines[2].kind == .Del && f.lines[2].old_no == 11 && f.lines[2].new_no == 0, "a deletion has only an old number")
			check(f.lines[3].kind == .Add && f.lines[3].new_no == 11 && f.lines[4].new_no == 12, "additions numbered on the new side")
			check(f.lines[5].old_no == 12 && f.lines[5].new_no == 13, "context after the change")
			check(files[1].status == "added" && files[1].new_path == "new.txt" && files[1].lines[1].new_no == 1, "an added file")
			check(files[2].status == "binary" && diff_path(files[2]) == "img.png", "a binary file keeps its path")
		}
	}

	// activity lines
	{
		o := json.Object{}
		pl := json.Object{}
		pl["commits"] = json.Integer(3)
		pl["ref"] = json.String("refs/heads/main")
		pl["after"] = json.String("abc")
		o["kind"] = json.String("push")
		o["payload"] = pl
		check(event_text(o) == "pushed 3 commits to main", "push event text: %s", event_text(o))
		pl2 := json.Object{}
		pl2["number"] = json.Integer(2)
		pl2["method"] = json.String("fast-forward")
		o2 := json.Object{}
		o2["kind"] = json.String("pull.merged")
		o2["payload"] = pl2
		check(event_text(o2) == "merged pull request #2 (fast-forward)", "merge event text")
	}

	// the lexer, as the file view uses it
	{
		toks := make([dynamic]Token, context.temp_allocator)
		lex_line(`main :: proc() { fmt.println("hi") // say it`, {}, &toks, .Odin)
		kinds := make(map[Tok]bool, context.temp_allocator)
		for t in toks {
			kinds[t.kind] = true
		}
		check(kinds[.Keyword] && kinds[.Str] && kinds[.Comment], "Odin line has keyword, string and comment tokens")
		check(lang_for_path("src/main.odin") == .Odin && lang_for_path("README.md") == .Markdown, "language from path")
	}

	fmt.printfln("forge selftest: %d passed, %d failed", passed, failed)
	return 0 if failed == 0 else 1
}
