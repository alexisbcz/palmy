#!/usr/bin/env bash
# The recorder launches a binary with no arguments, and an editor with no file
# open is not much of a demo.
#
# This writes a scratch file in /tmp and opens that, so the demo never edits
# the repository and never touches anything of the user's. The file is written
# here rather than copied from the tree so that the demo shows the same text
# every time, whatever the tree happens to contain today.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR=/tmp/palmy-editor-demo
mkdir -p "$DIR"

SRC="$DIR/widget.odin"
cat > "$SRC" <<'ODIN'
package demo

// A long line of prose, so that soft wrap has something to do: this comment is one single logical line with no newline anywhere in it, which without wrapping can only be read through a horizontal scrollbar, and nobody reads prose through a horizontal scrollbar.

import "core:strings"

Theme :: struct {
	name:    string,
	radius:  f32,
	density: int,
}

// draw paints one widget. The ctx argument is threaded through every call,
// which makes it the obvious thing to rename with several cursors at once.
draw :: proc(ctx: ^Ctx, r: Rect, th: Theme) {
	begin(ctx)
	fill(ctx, r, th.radius)
	label(ctx, th.name)
	end(ctx)
}

layout :: proc(ctx: ^Ctx, th: Theme) {
	measure(ctx, th.density)
	place(ctx)
}
ODIN

# Two more files, so the language picker has somewhere to go. The demo only
# opens the first; these are here because a demo that pretends the editor
# knows one language would be the old demo.
cat > "$DIR/theme.json" <<'JSON'
{
  "name": "shadcn",
  "radius": 0.5,
  "colors": { "primary": "#18181b", "muted": "#f4f4f5" },
  "dark": true,
  "fallback": null
}
JSON

cat > "$DIR/README.md" <<'MD'
# palmy editor

A **line array** buffer, a real tokeniser, and *soft wrap* that the caret
survives. See [the notes](../notes) for where the wrapping came from.

- [x] soft wrap
- [ ] everything else
MD

exec "$HERE/editor.bin" "$SRC"
