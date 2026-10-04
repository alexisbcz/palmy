import { Link } from "react-router";
import { CodeBlock } from "~/components/code-block";
import { Callout, DataTable, Lede } from "~/components/bits";
import type { DocPage } from "~/lib/doc";

const BUILD = `# Odin resolves \`palmy:.\` through a collection, so the toolkit can live
# anywhere. Point these at your checkout.
PALMFRAME=/path/to/palmframe

odin build "$PALMFRAME/apps/notes" \\
  -collection:palmy="$PALMFRAME/palmy" \\
  -collection:shadcn="$PALMFRAME/shadcn" \\
  -collection:kit="$PALMFRAME/apps/kit" \\
  -o:speed -out:notes.bin`;

export const PALMY_DOCS: DocPage[] = [
  /* ---------------------------------------------------------------------- */
  {
    slug: "introduction",
    title: "Introduction",
    description:
      "A UI toolkit written from scratch in Odin, speaking Wayland and X11 directly, with Tailwind class strings and a software rasterizer.",
    lead: () => (
      <>
        <Lede>
          palmy is a UI toolkit written from scratch in Odin. Components are
          procedures, styling is Tailwind class strings, and the result is
          pixels written straight into the display server&rsquo;s shared memory.
        </Lede>
        <CodeBlock
          lang="odin"
          code={`for ui in palmy.frames(app) {
	palmy.div(ui, "flex-col items-center justify-center w-full h-full gap-4 bg-slate-950")
	defer palmy.end(ui)

	palmy.textf(ui, "text-5xl font-bold text-white", "%d", count)

	if palmy.button(ui, "Add one", "bg-indigo-500 hover:bg-indigo-400 border-indigo-400") {
		count += 1
	}
}`}
        />
      </>
    ),
    sections: [
      {
        id: "the-dependency-list",
        title: "The dependency list",
        body: () => (
          <>
            <p>
              This is <code>ldd</code> on a palmy binary. It is the whole
              dependency list.
            </p>
            <CodeBlock
              lang="text"
              copy={false}
              code={`linux-vdso.so.1
libm.so.6
libc.so.6`}
            />
            <p>
              There is no libwayland, no GTK or Qt, no GPU driver and no font
              library. The toolkit came first because the rest of Palmframe is
              not worth attempting on a stack you cannot see the bottom of.
            </p>
          </>
        ),
      },
      {
        id: "what-is-hand-rolled",
        title: "What is hand-rolled",
        body: () => (
          <ul>
            <li>
              <strong>Both display protocols.</strong> Wayland messages are
              encoded onto a unix socket by hand, with file descriptors passed
              in <code>SCM_RIGHTS</code> control messages. The X11 core protocol
              is framed on the same socket machinery, authenticated with a
              cookie from the X authority file, and presents through MIT-SHM.
              There is no libwayland, no libX11 and no libxcb.
            </li>
            <li>
              <strong>Rendering is a software rasterizer</strong> — antialiased
              rounded rectangles, borders, shadows, gradients and lines,
              computed from signed distance fields and written into the
              shared-memory buffer the compositor is about to show.
            </li>
            <li>
              <strong>Layout is flexbox</strong> — the subset real interfaces
              use, following CSS closely enough that a browser is a reliable
              mental model.
            </li>
            <li>
              <strong>Styling is Tailwind</strong> — the class names you already
              know, resolving against the real Tailwind palette generated from{" "}
              <code>tailwindcss@3.4.17</code>, so <code>bg-slate-900</code> is{" "}
              <code>#0f172a</code> here too.
            </li>
            <li>
              <strong>Text is real TrueType</strong> — glyphs rasterized through
              stb_truetype from whatever font is installed, with kerning, word
              wrap, a slant axis, tabular figures, glyph outlines, colour-bitmap
              emoji and a glyph cache.
            </li>
          </ul>
        ),
      },
      {
        id: "how-it-is-judged",
        title: "How it is judged",
        body: () => (
          <>
            <p>
              Nothing here was styled by eye. A test rig renders all 61
              shadcn/ui components twice — once by Chromium from the real React
              source, once by palmy — and reports the difference per component.
              The font metrics, the subpixel glyph positioning, the linear-light
              coverage blending and the design-token system were each calibrated
              by measurement rather than guessed.
            </p>
            <p>
              See <Link to="/docs/parity">Measured against a browser</Link> for
              the numbers, and{" "}
              <Link to="/docs/limitations">What is not here</Link> for the list
              of things it genuinely does not do.
            </p>
          </>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "installation",
    title: "Installation",
    description:
      "What you need on the machine, how the collections are wired, and the build command.",
    lead: () => (
      <Lede>
        palmy is not a package you install. It is a directory of Odin source
        that you point a collection at, which is why the dependency list above
        is three lines long.
      </Lede>
    ),
    sections: [
      {
        id: "prerequisites",
        title: "Prerequisites",
        body: () => (
          <>
            <DataTable
              head={["What", "Which"]}
              rows={[
                [
                  "Odin",
                  <>
                    Built and tested with <code>dev-2026-09</code>.
                  </>,
                ],
                ["Linux", "Linux only. No macOS, no Windows."],
                [
                  "A compositor",
                  <>
                    Any compositor implementing <code>xdg-shell</code>, or any X
                    server with a little-endian 32-bit TrueColor screen.
                  </>,
                ],
                [
                  "A font",
                  "Any installed TrueType font. Discovery walks the system font directories; nothing is bundled.",
                ],
              ]}
            />
            <p>
              Nothing else. There is no <code>pkg-config</code> step, no header
              to find and no shared library to link, because every protocol the
              toolkit speaks is implemented in the toolkit.
            </p>
          </>
        ),
      },
      {
        id: "the-build-command",
        title: "The build command",
        body: () => (
          <>
            <p>
              Odin resolves an import like <code>palmy:.</code> through a
              collection flag, so the toolkit can live anywhere on disk.
            </p>
            <CodeBlock lang="bash" code={BUILD} />
            <p>
              Three collections appear in this repository. <code>palmy</code> is
              the toolkit. <code>shadcn</code> is the widget layer measured
              against the browser — see{" "}
              <Link to="/components">Components</Link>. <code>kit</code> is the
              shared application setup, which exists so forty applications do
              not each write their own font loading.
            </p>
          </>
        ),
      },
      {
        id: "a-first-window",
        title: "A first window",
        body: () => (
          <>
            <CodeBlock
              lang="odin"
              title="main.odin"
              code={`package main

import "core:fmt"
import "core:os"
import palmy "palmy:."

main :: proc() {
	app, err := palmy.create({title = "Hello", width = 480, height = 320})
	if err != "" {
		fmt.eprintfln("hello: %s", err)
		os.exit(1)
	}
	defer palmy.destroy(app)

	count := 0
	for ui in palmy.frames(app) {
		palmy.col(ui, "w-full h-full items-center justify-center gap-4 bg-slate-950")
		defer palmy.end(ui)

		palmy.textf(ui, "text-5xl font-bold text-white", "%d", count)
		if palmy.button(ui, "Add one") {
			count += 1
		}
	}
}`}
            />
            <Callout kind="note">
              <p>
                <code>create</code> returns an error <em>string</em>, not an
                enum, and it is empty on success. Everything the toolkit can
                refuse — no display server in the environment, an X screen it
                cannot present into, a layer surface asked for on X11 — says so
                in that string rather than failing later or drawing garbage.
              </p>
            </Callout>
          </>
        ),
      },
      {
        id: "the-shared-setup",
        title: "The shared application setup",
        body: () => (
          <>
            <p>
              An application that wants to look like the measured widget set
              goes through <code>kit.start</code> instead of{" "}
              <code>palmy.create</code>. It opens the window, loads the four
              static font faces the parity rig uses, registers the design tokens
              and applies the text gamma that was measured against Chromium.
            </p>
            <CodeBlock
              lang="odin"
              code={`import kit "kit:."

app, err := kit.start({
	title      = "Notes",
	width      = 1100,
	height     = 720,
	min_width  = 820,
	min_height = 480,
})
// fonts, the shadcn theme and the text calibration are already applied`}
            />
          </>
        ),
      },
      {
        id: "running-the-examples",
        title: "Running the examples",
        body: () => (
          <>
            <CodeBlock
              lang="bash"
              code={`make            # build every example into ./bin
make run-todo   # or run-counter, run-gallery, run-pixels
make test       # the headless test suite
make shots      # render the documentation images offscreen`}
            />
            <DataTable
              head={["Example", "What it shows"]}
              rows={[
                [<code>counter</code>, "the smallest complete app"],
                [
                  <code>todo</code>,
                  "text entry, keyed lists, filtering, scrolling",
                ],
                [
                  <code>gallery</code>,
                  "every widget, the palette, the type scale",
                ],
                [<code>pixels</code>, "the raw buffer, no UI layer at all"],
              ]}
            />
          </>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "the-frame-loop",
    title: "The frame loop",
    description:
      "A frame is a procedure call: you describe what the interface is right now and the loop blocks until something happens.",
    lead: () => (
      <Lede>
        A frame is a procedure call. You describe what the interface{" "}
        <em>is</em> right now, palmy works out what changed, and the loop blocks
        until something happens.
      </Lede>
    ),
    sections: [
      {
        id: "create-and-frames",
        title: "create, frames, destroy",
        body: () => (
          <>
            <CodeBlock
              lang="odin"
              code={`app, err := palmy.create({title = "Hello", width = 480, height = 320})
if err != "" { /* ... */ }
defer palmy.destroy(app)

for ui in palmy.frames(app) {
	// build the tree here
}`}
            />
            <p>
              <code>frames</code> is an iterator. Each turn gives you a{" "}
              <code>^Ctx</code> — the frame under construction — and it stops
              when the window closes. Between turns the loop sits in{" "}
              <code>poll</code>: an idle palmy window uses no CPU at all.
            </p>
          </>
        ),
      },
      {
        id: "config",
        title: "Config",
        body: () => (
          <>
            <p>Every field of the struct passed to <code>create</code>:</p>
            <CodeBlock
              lang="odin"
              code={`Config :: struct {
	title:      string,
	app_id:     string,
	width:      int,
	height:     int,
	min_width:  int,
	min_height: int,

	root_class: string,   // classes applied to the root element

	decorate:   bool,     // ask the compositor to draw a title bar
	always:     bool,     // redraw every vsync instead of only on change

	layer:          bool, // open as a wlr-layer-shell surface
	layer_level:    Layer,
	layer_anchor:   Anchor,
	layer_keyboard: Keyboard_Mode,
	exclusive_zone: int,
	layer_margin:   [4]int,  // top, right, bottom, left
}`}
            />
            <p>
              <code>always</code> is the escape hatch for something that must
              animate continuously. Without it, only the frames that are
              actually changing get drawn — input, a resize, a running
              transition, or an explicit <code>redraw(ui)</code>.
            </p>
          </>
        ),
      },
      {
        id: "elements",
        title: "Elements",
        body: () => (
          <>
            <p>
              Elements nest with <code>div</code>/<code>end</code>, which pairs
              well with <code>defer</code>.
            </p>
            <CodeBlock
              lang="odin"
              code={`palmy.col(ui, "gap-4 p-6 bg-slate-900 rounded-xl border border-slate-800")
defer palmy.end(ui)

palmy.text(ui, "Settings", "text-sm font-semibold text-white")
palmy.text(ui, "These apply to every project.", "text-xs text-slate-500")`}
            />
            <DataTable
              head={["Procedure", "What it is"]}
              rows={[
                [
                  <code>div(ui, class) -&gt; int</code>,
                  "a plain box; returns its index in the tree",
                ],
                [
                  <code>row(ui, class)</code>,
                  <>
                    the same with <code>flex-row</code> already set
                  </>,
                ],
                [
                  <code>col(ui, class)</code>,
                  <>
                    the same with <code>flex-col</code> already set
                  </>,
                ],
                [<code>text(ui, str, class)</code>, "a run of text"],
                [
                  <code>textf(ui, class, format, args)</code>,
                  "the same, formatted",
                ],
                [<code>end(ui)</code>, "close the current element"],
                [<code>spacer(ui, class)</code>, "an empty flex-1 box"],
                [<code>divider(ui, class)</code>, "a hairline"],
                [<code>icon(ui, ic, class)</code>, "a stroked line icon"],
                [
                  <code>image(ui, img, class, fit, zoom)</code>,
                  "a decoded bitmap",
                ],
              ]}
            />
            <Callout kind="warn" title="end is not optional">
              <p>
                The tree is a flat array with a cursor, so a missing{" "}
                <code>end</code> does not crash — it silently nests everything
                that follows inside the element you forgot to close.{" "}
                <code>defer palmy.end(ui)</code> immediately after the opener is
                the habit worth forming.
              </p>
            </Callout>
          </>
        ),
      },
      {
        id: "what-the-loop-does",
        title: "What the loop actually does",
        body: () => (
          <ul>
            <li>
              <strong>The socket.</strong> Requests are built into a byte buffer
              — object id, opcode and size packed into two words, then arguments
              — and flushed with <code>sendmsg</code>. File descriptors, such as
              the shared-memory pool, ride along in an <code>SCM_RIGHTS</code>{" "}
              control message. Object ids are only recycled once the server
              confirms.
            </li>
            <li>
              <strong>The buffers.</strong> One <code>memfd</code> holds two
              frames, mapped into the process and shared with the compositor.
              Drawing goes into whichever buffer is not on screen; a release
              event says when one is free again.
            </li>
            <li>
              <strong>The frame.</strong> Elements are appended to a flat array
              as you call <code>div</code> and <code>text</code>. Two arrays are
              kept, this frame&rsquo;s and the last, so hit testing and
              scrolling can run against real geometry before the new tree
              exists. All per-frame allocation goes into an arena that is reset,
              not freed.
            </li>
            <li>
              <strong>Layout</strong> measures the tree with the space
              available, then arranges it, resolving grow, shrink, wrapping,
              justification and alignment. Flex items get CSS&rsquo;s automatic
              minimum size, so a scrolling column overflows instead of squashing
              its contents.
            </li>
            <li>
              <strong>Paint</strong> walks the tree in order: shadow,
              background, border, content, children, scrollbar. Shapes are
              evaluated through a signed distance field at the edges and filled
              with flat spans in the middle, so a full-window panel costs about
              what a memset costs.
            </li>
          </ul>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "state",
    title: "State",
    description:
      "Odin has no closures, so palmy does not pretend otherwise: state lives in ordinary variables, or in state() when it belongs to one element.",
    lead: () => (
      <Lede>
        Odin has no closures, so palmy does not pretend otherwise. Your state
        lives in ordinary variables in the loop, or in a struct you pass down.
      </Lede>
    ),
    sections: [
      {
        id: "ordinary-variables",
        title: "Ordinary variables",
        body: () => (
          <>
            <CodeBlock
              lang="odin"
              code={`count := 0
for ui in palmy.frames(app) {
	if palmy.button(ui, "+") { count += 1 }
}`}
            />
            <p>
              This is the common case and it is worth leaning on. There is no
              store, no reducer and no subscription: the loop is a loop, and the
              variable it closes over is a variable.
            </p>
          </>
        ),
      },
      {
        id: "element-state",
        title: "State that belongs to an element",
        body: () => (
          <>
            <p>
              When a piece of state belongs to one element rather than to the
              program — whether a disclosure is open, how far a panel has
              scrolled — <code>state</code> keeps it alive between frames, keyed
              by position in the tree.
            </p>
            <CodeBlock
              lang="odin"
              code={`open := palmy.state(ui, "open", false)
if palmy.button(ui, "Details") { open^ = !open^ }
if open^ {
	palmy.text(ui, "...")
}`}
            />
            <p>
              <code>state</code> is generic over the initial value and returns a
              pointer, so <code>open^</code> reads and writes the same cell next
              frame. A <code>[dynamic]u8</code> held this way is how a text
              field gets a buffer that survives:
            </p>
            <CodeBlock
              lang="odin"
              code={`buf := palmy.state(ui, "name", [dynamic]u8{})
changed, submitted := palmy.text_field(ui, buf, "Your name")`}
            />
          </>
        ),
      },
      {
        id: "the-keying-rule",
        title: "The keying rule",
        body: () => (
          <Callout kind="warn">
            <p>
              Because the key is the position in the tree, two sibling{" "}
              <code>state</code> calls with the same name in the same place are
              the same cell, and inserting an element above a stateful one
              shifts its identity. In a list that reorders or filters, that is
              exactly the wrong behaviour — which is what{" "}
              <Link to="/docs/identity-and-keys">key</Link> is for.
            </p>
          </Callout>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "identity-and-keys",
    title: "Identity and keys",
    description:
      "Elements are identified by where they sit in the tree. Lists are the exception, and key is how you tell palmy which item an element is showing.",
    lead: () => (
      <Lede>
        Elements are identified by where they sit in the tree, so nothing needs
        naming in the common case. Lists are the exception.
      </Lede>
    ),
    sections: [
      {
        id: "key",
        title: "key",
        body: () => (
          <>
            <p>
              <code>key</code> ties the next element to the item it is showing,
              so state follows the item when the list is reordered or filtered.
            </p>
            <CodeBlock
              lang="odin"
              code={`for task in tasks {
	palmy.key(ui, task.id_string)
	palmy.row(ui, "items-center gap-3 p-3 rounded-lg bg-slate-900")
	palmy.checkbox(ui, "", &task.done)
	palmy.text(ui, task.text, task.done ? "line-through text-slate-500" : "")
	palmy.end(ui)
}`}
            />
            <p>
              It applies to the <em>next</em> element pushed, and it must come
              before the opener, not inside it. The string needs to be stable
              for the life of the item, not merely unique this frame: an index
              is not a key, because the whole point is to survive reordering.
            </p>
          </>
        ),
      },
      {
        id: "what-identity-buys",
        title: "What identity buys you",
        body: () => (
          <ul>
            <li>
              <strong>State follows the item.</strong> A half-typed edit stays
              with the row it belongs to when a filter removes the row above it.
            </li>
            <li>
              <strong>Focus follows the item.</strong> Focus is held as an id,
              so the focused row stays focused rather than the position staying
              focused.
            </li>
            <li>
              <strong>Scroll offsets survive.</strong> A nested scrolling panel
              in a keyed list keeps its own position.
            </li>
          </ul>
        ),
      },
      {
        id: "inspecting-the-tree",
        title: "Inspecting the tree",
        body: () => (
          <>
            <p>
              Every element procedure returns its index, and the index is what
              the inspection procedures take. This is also what makes layout
              assertable from a test.
            </p>
            <CodeBlock
              lang="odin"
              code={`at := palmy.node_count(ui)
palmy.button(ui, "Save")
// after the frame:
r := palmy.node_rect(ui, at)   // Rect{x, y, w, h}`}
            />
            <p>
              <code>node_rect</code>, <code>node_id</code>,{" "}
              <code>node_parent</code>, <code>node_kind</code>,{" "}
              <code>node_text</code> and <code>node_style</code> all take an
              index. <code>node_rect</code> reports the previous frame&rsquo;s
              geometry during a frame, which is also how an application finds
              out where to put a menu it is about to draw.
            </p>
          </>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "interaction",
    title: "Interaction",
    description:
      "Widgets return what happened. Any element becomes clickable with clickable, and the keyboard has one trap worth knowing about.",
    lead: () => (
      <Lede>
        Widgets return what happened. Hit testing runs against the previous
        frame, which is what makes <code>hover:</code> and <code>active:</code>{" "}
        work without a retained tree.
      </Lede>
    ),
    sections: [
      {
        id: "clickable",
        title: "clickable",
        body: () => (
          <>
            <CodeBlock
              lang="odin"
              code={`palmy.div(ui, "p-4 rounded-xl bg-slate-900 hover:bg-slate-800 transition cursor-pointer")
if palmy.clickable(ui) {
	open(item)
}
palmy.text(ui, item.name)
palmy.end(ui)`}
            />
            <p>
              With no index, these apply to the element just pushed. Pass one to
              reach back at an element you opened earlier in the frame.
            </p>
          </>
        ),
      },
      {
        id: "the-interaction-procedures",
        title: "The interaction procedures",
        body: () => (
          <DataTable
            head={["Procedure", "Answers"]}
            rows={[
              [
                <code>clickable(ui, idx) -&gt; bool</code>,
                "was this element clicked",
              ],
              [
                <code>focusable(ui, idx)</code>,
                "join the Tab order (returns nothing)",
              ],
              [
                <code>activated(ui, idx) -&gt; bool</code>,
                "clicked, or Enter/Space while focused",
              ],
              [
                <code>is_hovered(ui, idx) -&gt; bool</code>,
                "the pointer is over it",
              ],
              [
                <code>is_active(ui, idx) -&gt; bool</code>,
                "hovered while the button is held",
              ],
              [
                <code>focused(ui, idx) -&gt; bool</code>,
                "it holds the keyboard focus",
              ],
              [
                <code>key_pressed(ui, sym, include_repeat) -&gt; bool</code>,
                "was a key pressed this frame",
              ],
              [
                <code>key_count(ui, sym, include_repeat) -&gt; int</code>,
                "how many times",
              ],
              [
                <code>shortcut(ui, sym, mods, include_repeat) -&gt; bool</code>,
                "a chord, with modifiers",
              ],
              [
                <code>wheel(ui) -&gt; [2]f32</code>,
                "scroll deltas this frame",
              ],
              [
                <code>typed_text(ui) -&gt; string</code>,
                "the text committed this frame",
              ],
              [
                <code>set_focus(ui, id)</code>,
                <>
                  move focus, by the id from <code>node_id</code>
                </>,
              ],
            ]}
          />
        ),
      },
      {
        id: "key-pressed-vs-key-count",
        title: "key_pressed is not key_count",
        body: () => (
          <>
            <Callout kind="warn" title="This one bites under synthetic input">
              <p>
                <code>key_pressed</code> answers <em>was it pressed</em>, not{" "}
                <em>how many times</em>. Several presses can arrive in one frame
                and collapse to a single <code>true</code>, so two taps of{" "}
                <code>j</code> move one row. A driver script sends keys far
                faster than a human does, so this shows up immediately in a
                recorded demo and almost never while you are clicking around by
                hand.
              </p>
            </Callout>
            <CodeBlock
              lang="odin"
              code={`// wrong for navigation: two fast presses become one step
if palmy.key_pressed(ui, palmy.KEY_DOWN) { selected += 1 }

// right: act once per press that actually arrived
for _ in 0 ..< palmy.key_count(ui, palmy.KEY_DOWN) {
	selected = min(selected + 1, len(rows) - 1)
}`}
            />
            <p>
              Where one press must equal one step — navigation, a nudge,
              stepping a value — use <code>key_count</code>. Where the question
              really is a boolean — is Shift held, did Escape happen — use{" "}
              <code>key_pressed</code>.
            </p>
          </>
        ),
      },
      {
        id: "key-constants",
        title: "Key constants",
        body: () => (
          <>
            <p>
              These are the named symbols the toolkit defines. Ordinary
              characters come through as text rather than as constants.
            </p>
            <CodeBlock
              lang="text"
              copy={false}
              code={`KEY_BACKSPACE  KEY_TAB        KEY_RETURN     KEY_ESCAPE
KEY_HOME       KEY_END        KEY_INSERT     KEY_DELETE
KEY_LEFT       KEY_UP         KEY_RIGHT      KEY_DOWN
KEY_PAGE_UP    KEY_PAGE_DOWN  KEY_KP_ENTER   KEY_SPACE
KEY_F1         KEY_F2         KEY_F3         KEY_F4
KEY_F5         KEY_F11`}
            />
            <Callout kind="note">
              <p>
                That list is the whole set — there is no <code>KEY_F6</code>{" "}
                through <code>KEY_F10</code>, no <code>KEY_F12</code>, and no
                constants for the modifier keys themselves. Modifiers arrive as
                the <code>mods</code> argument to <code>shortcut</code>.
              </p>
            </Callout>
          </>
        ),
      },
      {
        id: "text-entry",
        title: "Text entry",
        body: () => (
          <>
            <CodeBlock
              lang="odin"
              code={`buf := palmy.state(ui, "query", [dynamic]u8{})
changed, submitted := palmy.text_field(ui, buf, "What needs doing?")
if submitted {
	add(string(buf[:]))
	clear(buf)
}

// a password field: the bytes stay in buf, the screen shows the mask
palmy.text_field(ui, pw, "Password", "", '•')`}
            />
            <p>
              The field supports arrows, Home and End, Backspace, Delete and
              Ctrl-A/E/U, with key repeat at the compositor&rsquo;s configured
              rate. Tab cycles focus and Space and Enter activate, for every
              widget, without being asked.
            </p>
            <p>
              For a real text editor there are two measurements, and they
              round-trip against each other — see{" "}
              <Link to="/docs/text">Text</Link>. Selection across lines, styled
              runs and undo are deliberately not here: that model belongs to the
              application.
            </p>
          </>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "classes",
    title: "Classes",
    description:
      "The Tailwind subset palmy implements, the variants, the ordering rule, and the escape hatch when a class cannot express something.",
    lead: () => (
      <Lede>
        Utilities are applied in order, so later ones win and your classes
        always beat a widget&rsquo;s defaults. The variants{" "}
        <code>hover:</code>, <code>active:</code>, <code>focus:</code> and{" "}
        <code>disabled:</code> apply when the element is in that state.
      </Lede>
    ),
    sections: [
      {
        id: "the-subset",
        title: "The subset",
        body: () => (
          <DataTable
            head={["Group", "Supported"]}
            rows={[
              [
                "layout",
                <code>
                  flex-row flex-col flex-wrap items-* justify-* self-* gap-*
                  gap-x-* gap-y-* hidden relative absolute inset-0
                  top/right/bottom/left-* z-*
                </code>,
              ],
              [
                "sizing",
                <code>
                  w-* h-* size-* w-full h-full w-screen w-1/2 min-w-* max-w-*
                  min-h-* max-h-* basis-* flex-1 flex-auto flex-none grow grow-0
                  shrink shrink-0
                </code>,
              ],
              [
                "spacing",
                <code>
                  p-* px-* py-* pt/pr/pb/pl-*, the same for m-*, mx-auto
                </code>,
              ],
              [
                "color",
                <code>
                  bg-* text-* border-*, bg-gradient-to-b with from-*/to-*,
                  opacity suffixes like bg-white/10, arbitrary values like
                  bg-[#1e293b]
                </code>,
              ],
              [
                "border",
                <code>
                  border border-2 border-t-2 rounded rounded-lg rounded-full
                  rounded-t-xl rounded-[10]
                </code>,
              ],
              [
                "text",
                <code>
                  text-xs … text-9xl font-bold font-mono italic not-italic
                  tabular-nums text-center leading-* tracking-* uppercase
                  truncate whitespace-nowrap line-through underline
                  text-outline-2 text-outline-black
                </code>,
              ],
              [
                "effects",
                <code>
                  shadow shadow-sm … shadow-2xl opacity-* transition duration-*
                </code>,
              ],
              ["overflow", <code>overflow-hidden overflow-scroll</code>],
              [
                "cursor",
                <code>
                  cursor-pointer cursor-text cursor-crosshair cursor-grab …
                </code>,
              ],
            ]}
          />
        ),
      },
      {
        id: "the-scale",
        title: "The scale",
        body: () => (
          <>
            <p>
              Spacing follows Tailwind&rsquo;s scale — <code>p-4</code> is 16px,{" "}
              <code>p-0.5</code> is 2px, <code>p-px</code> is 1px — and anything
              in brackets is exact pixels (<code>w-[260]</code>). Colours
              resolve against the real Tailwind palette, generated from{" "}
              <code>tailwindcss@3.4.17</code>.
            </p>
            <p>
              <code>transition</code> eases background, text and border colours
              toward their target, so <code>hover:</code> states fade rather
              than snap. Only the frames that are actually animating get drawn.
              It eases <em>colours</em>, not geometry: moving a box is the
              application&rsquo;s arithmetic.
            </p>
          </>
        ),
      },
      {
        id: "design-tokens",
        title: "Design tokens",
        body: () => (
          <>
            <p>
              A class name can resolve against a registered token instead of the
              palette, which is what lets the widget layer use class strings
              that read like the TSX they were ported from —{" "}
              <code>bg-primary</code>, <code>text-muted-foreground</code>,{" "}
              <code>border-input</code>, <code>rounded-lg</code>,{" "}
              <code>ring-3</code>.
            </p>
            <CodeBlock
              lang="odin"
              code={`palmy.register_color("primary", palmy.hex(0x181818))
palmy.register_radius("lg", 10)
palmy.register_text("sm", 14, 20)

// and to go back to nothing
palmy.reset_theme()`}
            />
            <p>
              <code>theme_color</code>, <code>theme_radius</code> and{" "}
              <code>theme_text</code> read them back. The widget layer registers
              the whole shadcn set in one call.
            </p>
          </>
        ),
      },
      {
        id: "the-escape-hatch",
        title: "When a class cannot express it",
        body: () => (
          <>
            <CodeBlock
              lang="odin"
              code={`palmy.div(ui, "h-8 rounded-md")
palmy.style(ui).bg = palmy.flat(swatch)
palmy.end(ui)`}
            />
            <p>
              <code>style(ui)</code> returns a pointer to the element&rsquo;s
              resolved style, so a value that came out of a colour picker or a
              file does not have to be formatted into a class string first.{" "}
              <code>flat</code> and <code>gradient</code> build the paint.
            </p>
          </>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "widgets",
    title: "Widgets",
    description:
      "palmy's own widget set is small and owns its state. The shadcn layer on top is large and does not.",
    lead: () => (
      <Lede>
        Each widget takes a class string that overrides its defaults, and each
        is a few dozen lines built on the same primitives you have. They are a
        starting point, not a framework.
      </Lede>
    ),
    sections: [
      {
        id: "the-built-in-set",
        title: "The built-in set",
        body: () => (
          <>
            <CodeBlock
              lang="odin"
              code={`if palmy.button(ui, "Save") { save() }
palmy.checkbox(ui, "Accept terms", &accepted)
palmy.toggle(ui, &enabled)
palmy.slider(ui, &volume, 0, 100)
palmy.progress(ui, 0.66)
changed, submitted := palmy.text_field(ui, &buf, "What needs doing?")
palmy.spacer(ui)
palmy.divider(ui)`}
            />
            <p>
              These own their value: you pass a pointer and the widget mutates
              it. That is the right trade for a toolkit&rsquo;s own widgets, and
              the wrong one for a widget set that has to match a browser&rsquo;s
              pixels exactly.
            </p>
          </>
        ),
      },
      {
        id: "the-shadcn-layer",
        title: "The shadcn layer",
        body: () => (
          <>
            <p>
              The <code>shadcn</code> collection is all 61 shadcn/ui components
              written with palmy primitives and measured against Chromium
              rendering the real React source. Its widgets take an explicit{" "}
              <code>State</code> rather than reading pseudo-classes, so the
              caller decides when they apply:
            </p>
            <CodeBlock
              lang="odin"
              code={`import p "palmy:."
import sc "shadcn:."

sc.register_shadcn_theme()   // once, before the first frame
p.set_text_gamma(1.8)        // the calibration measured against Chromium

idx := sc.button_open(ui, .Outline, .Default, sc.State{
	hover    = p.is_hovered(ui),
	focus    = p.focused(ui),
	disabled = busy,
})
p.icon(ui, sc.ICON_DOWNLOAD, "size-4")
p.text(ui, "Download")
sc.button_end(ui)
if p.activated(ui, idx) { download() }`}
            />
            <p>
              <Link to="/components">The component reference</Link> has every
              one of them, the Odin that produces it, the React equivalent, and
              what the Odin version does and does not do.
            </p>
          </>
        ),
      },
      {
        id: "building-your-own",
        title: "Building your own",
        body: () => (
          <>
            <p>
              A widget here is not a privileged thing. It is a procedure that
              pushes elements and returns what happened, and yours look the
              same.
            </p>
            <CodeBlock
              lang="odin"
              code={`// A row that highlights on hover, joins the Tab order, and reports a click.
list_row :: proc(ui: ^palmy.Ctx, label: string, selected: bool) -> bool {
	cls := selected ? "bg-accent" : "hover:bg-accent/50"
	idx := palmy.row(ui, palmy.concat(ui,
		"items-center gap-3 px-3 py-2 rounded-md transition cursor-pointer ", cls))
	defer palmy.end(ui)

	palmy.focusable(ui, idx)
	palmy.text(ui, label, "text-sm")
	return palmy.activated(ui, idx)
}`}
            />
          </>
        ),
      },
      {
        id: "no-popups",
        title: "There are no popups",
        body: () => (
          <Callout kind="warn" title="A real constraint, not a gap to route around">
            <p>
              <code>xdg_popup</code> is not implemented and there is one window
              per process, so a menu, a tooltip, a dialog or a dropdown is drawn{" "}
              <em>inside</em> the window as an absolutely positioned overlay
              with a <code>z-</code> class. It cannot overhang the window edge.
            </p>
            <p>
              Every application in this repository that has a context menu does
              it this way, including ones held to a high standard for menus. The
              thing not to do is open a second window for it.
            </p>
          </Callout>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "text",
    title: "Text",
    description:
      "Real TrueType through stb_truetype: the italic axis, tabular figures, stroked glyphs, colour emoji, and the two measurements an editor needs.",
    lead: () => (
      <Lede>
        Glyphs are rasterized from whatever font is installed, with kerning,
        word wrap, a slant axis, tabular figures, glyph outlines, colour-bitmap
        emoji and a glyph cache.
      </Lede>
    ),
    sections: [
      {
        id: "the-italic-axis",
        title: "The italic axis",
        body: () => (
          <>
            <p>
              <code>italic</code> is a real axis, not a heavier weight.
              Discovery looks for <code>*-Italic</code> and{" "}
              <code>*-Oblique</code> files alongside the upright ones, and an
              italic request with no italic file on the machine falls back to a
              real italic at a neighbouring weight before it will settle for a
              sheared upright.
            </p>
            <CodeBlock
              lang="odin"
              code={`bold, oblique := palmy.font_is_synthetic(&app.fonts, .Sans, .Regular, .Italic)

// Force the shear — which is what you want after swapping the primaries for a
// family that ships no italic, since a sheared Geist still reads as Geist.
palmy.use_synthetic_italic(&app.fonts, .Sans, .Regular)`}
            />
          </>
        ),
      },
      {
        id: "tabular-figures",
        title: "Tabular figures",
        body: () => (
          <>
            <p>
              <code>tabular-nums</code> gives every digit the same advance, so a
              clock, a byte counter or a rate readout stops moving sideways as
              its digits change.
            </p>
            <p>
              There is no GSUB here to select the font&rsquo;s own{" "}
              <code>tnum</code> feature, so the slot is measured instead: the
              widest of the ten digits at that exact size, with each glyph
              centred in it. Measurement, drawing and hit testing all apply it,
              so carets and centred labels stay where the glyphs are.
            </p>
          </>
        ),
      },
      {
        id: "stroked-glyphs",
        title: "Stroked glyphs",
        body: () => (
          <>
            <p>
              <code>text-outline-2 text-outline-black</code> strokes every
              glyph, which is what a subtitle over a moving frame needs. The
              stroke is the glyph&rsquo;s own coverage mask dilated by the radius
              and cached, not the run drawn again at offsets, so it costs one
              rasterisation and the joins are round.
            </p>
          </>
        ),
      },
      {
        id: "colour-emoji",
        title: "Colour emoji",
        body: () => (
          <>
            <p>
              Colour emoji fonts have no outlines at all — their glyphs are PNGs
              in the <code>CBDT</code>/<code>CBLC</code> tables. palmy reads
              those tables directly, box-filters each strike down to the text
              size once, and caches it.
            </p>
            <p>
              A codepoint that defaults to the emoji presentation, or is followed
              by U+FE0F, goes to the colour font ahead of the outline fallbacks.
              One that defaults to text — <code>☀</code>, <code>❤</code>,{" "}
              <code>✔</code> — keeps its text glyph.
            </p>
            <Callout kind="note">
              <p>
                There is no GSUB, so an emoji ZWJ sequence renders as its parts
                rather than as one glyph.
              </p>
            </Callout>
          </>
        ),
      },
      {
        id: "measurement",
        title: "Measurement",
        body: () => (
          <>
            <p>
              Beyond <code>text_field</code>, which is a single-line widget,
              palmy gives you the two measurements a real text editor needs.
              They are rune-safe and they round-trip against each other.
            </p>
            <CodeBlock
              lang="odin"
              code={`// Where does a click land in this string?
i := palmy.text_index_at(&app.fonts, line, size, click_x)

// Where does the caret at index i sit?
x := palmy.text_width_upto(&app.fonts, line, i, size)

// And the whole run
w := palmy.text_width(&app.fonts, line, size)`}
            />
            <p>
              All three take the same trailing options as drawing does — family,
              weight, tracking, slant and whether figures are tabular — so a
              measurement and the glyphs it is measuring cannot disagree about
              which face they mean.
            </p>
            <CodeBlock
              lang="odin"
              code={`text_width :: proc(
	f: ^Fonts,
	text: string,
	size: f32,
	fam := Font_Family.Sans,
	wt := Font_Weight.Regular,
	tracking: f32 = 0,
	sl := Font_Slant.Upright,
	tabular := false,
) -> f32`}
            />
          </>
        ),
      },
      {
        id: "what-text-does-not-do",
        title: "What it does not do",
        body: () => (
          <ul>
            <li>
              Left to right only, with simple word wrapping. No bidi.
            </li>
            <li>
              No complex shaping. Missing glyphs come from a fallback chain, but
              there is no GSUB, so Arabic and Indic scripts are unjoined.
            </li>
            <li>
              No input method support and no preedit, so CJK input will not
              work.
            </li>
            <li>Grayscale antialiasing, no subpixel rendering.</li>
          </ul>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "images",
    title: "Images",
    description:
      "Decoding through stb_image, bilinear sampling that switches to nearest when magnified, and the path down to compositing frames yourself.",
    lead: () => (
      <Lede>
        palmy decodes images through stb_image — PNG, JPEG, BMP, GIF, TGA, PSD,
        PNM and HDR. Pixels are straight <code>0xAARRGGBB</code> and composite
        like anything else.
      </Lede>
    ),
    sections: [
      {
        id: "decoding-and-drawing",
        title: "Decoding and drawing",
        body: () => (
          <>
            <CodeBlock
              lang="odin"
              code={`img, ok := palmy.load_image("photo.jpg")
defer palmy.image_destroy(&img)

palmy.image(ui, img, "w-full h-full", .Contain)   // .Contain .Cover .Fill .None
palmy.image(ui, img, "w-full h-full", .None, zoom) // magnify around the centre

w, h, ch, ok := palmy.image_size(path)  // dimensions without decoding pixels
palmy.is_image_path(path)               // a cheap extension check
palmy.write_png_rgba(path, rgba, w, h)  // save`}
            />
            <p>
              Sampling is bilinear, switching to nearest past 2&times;
              magnification so a zoomed photo shows real pixels rather than
              mush.
            </p>
          </>
        ),
      },
      {
        id: "compositing-yourself",
        title: "Compositing frames yourself",
        body: () => (
          <>
            <p>
              <code>draw_image</code> is available directly inside a raw pixel
              callback if you need to composite frames — which is how a video
              player blits decoded frames, and how the image viewer here
              implements zoom, pan and rotate rather than using the widget.
            </p>
            <p>
              See <Link to="/docs/drawing">Drawing pixels</Link> for the two
              ways down to the buffer.
            </p>
          </>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "drawing",
    title: "Drawing pixels",
    description:
      "Two ways down to the buffer: a panel inside the layout, or the whole window with no UI layer at all.",
    lead: () => (
      <Lede>
        Two ways down to the buffer. Both hand you the same canvas, and the
        rasterizer is available in both.
      </Lede>
    ),
    sections: [
      {
        id: "a-panel",
        title: "A panel inside the layout",
        body: () => (
          <>
            <p>
              <code>pixels</code> gives a procedure the element&rsquo;s
              rectangle and the canvas, with your own data pointer threaded
              through. Odin has no closures, which is why the pointer is
              explicit.
            </p>
            <CodeBlock
              lang="odin"
              code={`palmy.pixels(ui, "flex-1 rounded-xl overflow-hidden", &scene,
	proc(c: ^palmy.Canvas, r: palmy.Rect, s: ^Scene) {
		for y in int(r.y) ..< int(r.y + r.h) {
			row := c.px[y * c.w:][:c.w]
			for x in int(r.x) ..< int(r.x + r.w) {
				row[x] = shade(x, y, s.t)
			}
		}
	})`}
            />
          </>
        ),
      },
      {
        id: "the-whole-window",
        title: "The whole window",
        body: () => (
          <>
            <p>
              <code>direct_frames</code> skips the UI layer entirely and hands
              you the buffer each vsync.
            </p>
            <CodeBlock
              lang="odin"
              code={`for c in palmy.direct_frames(app) {
	for y in 0 ..< c.h {
		for x in 0 ..< c.w {
			c.px[y * c.w + x] = plasma(x, y, palmy.app_elapsed(app))
		}
	}
}`}
            />
          </>
        ),
      },
      {
        id: "the-canvas",
        title: "The canvas",
        body: () => (
          <>
            <CodeBlock
              lang="odin"
              code={`Rect   :: struct { x, y, w, h: f32 }
Radius :: [4]f32   // clockwise from top-left

Canvas :: struct {
	px:    []u32,   // 0xffRRGGBB
	w, h:  int,
	clip:  Rect,
	stack: [dynamic]Rect,
	scale: f32,     // device pixels per logical pixel
}`}
            />
            <DataTable
              head={["Procedure", ""]}
              rows={[
                [
                  <code>fill_rect(c, r, col)</code>,
                  "a flat rectangle",
                ],
                [
                  <code>fill_round_rect(c, r, rad, col)</code>,
                  "antialiased, per-corner radii",
                ],
                [
                  <code>stroke_round_rect(c, r, rad, width, col)</code>,
                  "the outline of one",
                ],
                [
                  <code>drop_shadow(c, r, rad, blur, spread, offset, col)</code>,
                  "a blurred shadow behind a shape",
                ],
                [<code>fill_circle(c, cx, cy, radius, col)</code>, ""],
                [<code>draw_line(c, x0, y0, x1, y1, thickness, col)</code>, ""],
                [
                  <code>draw_text(c, f, text, x, y, size, col, …)</code>,
                  "a run of glyphs; the trailing options are family, weight, tracking, slant, tabular and an outline",
                ],
                [
                  <code>blit_mask(c, x, y, mask, mw, mh, col)</code>,
                  "an 8-bit coverage mask, tinted",
                ],
                [
                  <code>push_clip(c, r)</code>,
                  <>
                    clip to a rectangle; <code>pop_clip(c)</code> restores
                  </>,
                ],
                [
                  <code>blend(c, x, y, col, cov)</code>,
                  "one antialiased pixel",
                ],
              ]}
            />
            <p>
              <code>fill_rect_paint</code> and <code>fill_round_rect_paint</code>{" "}
              take a <code>Paint</code> instead of a colour, built with{" "}
              <code>flat</code> or <code>gradient</code>.
            </p>
          </>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "layers",
    title: "Overlays, panels and launchers",
    description:
      "A layer-shell surface is what a launcher, panel, bar or notification actually needs, and it is one field in Config.",
    lead: () => (
      <Lede>
        A window is an <code>xdg-shell</code> toplevel by default. Set{" "}
        <code>layer</code> and palmy opens a <code>wlr-layer-shell</code>{" "}
        surface instead — a surface the compositor places itself.
      </Lede>
    ),
    sections: [
      {
        id: "an-overlay",
        title: "An overlay",
        body: () => (
          <>
            <CodeBlock
              lang="odin"
              code={`app, err := palmy.create({
	title = "launcher",
	width = 720, height = 520,
	layer          = true,
	layer_level    = .Overlay,    // .Background .Bottom .Top .Overlay
	layer_keyboard = .Exclusive,  // all key input comes here, like a launcher
})`}
            />
            <p>
              Leave <code>width</code> and <code>height</code> at 0 to fill
              whatever the compositor gives you — that is how a fullscreen
              greeter or a bar anchored to opposing edges asks for its size, and
              the compositor answers with the real one in its configure.
            </p>
          </>
        ),
      },
      {
        id: "a-bar",
        title: "A bar",
        body: () => (
          <>
            <p>
              Anchor it to edges, and reserve space so other windows tile around
              it.
            </p>
            <CodeBlock
              lang="odin"
              code={`layer_anchor   = {.Top, .Left, .Right},
exclusive_zone = 36,
layer_margin   = {8, 8, 0, 8},   // top, right, bottom, left`}
            />
            <p>
              Everything else — layout, input, drawing — is identical to an
              ordinary window.
            </p>
          </>
        ),
      },
      {
        id: "the-wayland-only-part",
        title: "The one Wayland-only feature",
        body: () => (
          <Callout kind="warn">
            <p>
              A layer surface requires a compositor implementing{" "}
              <code>zwlr_layer_shell_v1</code>, which the wlroots family and
              Hyprland do. It is the one thing that does not cross over to X11,
              and <code>create</code> says so rather than opening an ordinary
              window in the wrong place:
            </p>
            <CodeBlock
              lang="text"
              copy={false}
              code={`a layer surface needs wlr-layer-shell, which X11 has no equivalent
of; run this on a Wayland compositor, or open an ordinary window instead`}
            />
          </Callout>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "backends",
    title: "Wayland and X11",
    description:
      "One seam, two backends, and an application that cannot tell which it is on.",
    lead: () => (
      <Lede>
        The same binary runs on either, and an application cannot tell which it
        is on: the public API is identical and the rasterizer is shared, so a
        window and an offscreen render of the same tree are the same pixels.
      </Lede>
    ),
    sections: [
      {
        id: "which-backend",
        title: "Which backend",
        body: () => (
          <>
            <CodeBlock
              lang="text"
              copy={false}
              code={`WAYLAND_DISPLAY set    ->  Wayland
otherwise DISPLAY set  ->  X11
PALMY_BACKEND=x11      ->  X11, whatever the environment says
PALMY_BACKEND=wayland  ->  Wayland, likewise`}
            />
            <p>
              The override matters because a Wayland session with XWayland
              exports <code>DISPLAY</code> too, so the environment alone cannot
              say &ldquo;use X11&rdquo;. <code>PALMY_BACKEND</code> is checked
              first, and a value that is neither is an error rather than a
              silent fallback. With neither variable set at all,{" "}
              <code>create</code> says that too.
            </p>
          </>
        ),
      },
      {
        id: "what-each-speaks",
        title: "What each one speaks",
        body: () => (
          <DataTable
            head={["", "Wayland", "X11"]}
            rows={[
              [
                "window",
                <code>xdg-shell</code>,
                <>
                  core protocol, with <code>WM_PROTOCOLS</code>/
                  <code>WM_DELETE_WINDOW</code> so a window manager asks instead
                  of killing the process
                </>,
              ],
              [
                "presentation",
                <>
                  <code>wl_shm</code> pool, two buffers in one memfd
                </>,
                <>
                  MIT-SHM, with a chunked <code>PutImage</code> fallback
                </>,
              ],
              [
                "authentication",
                "none needed",
                "MIT-MAGIC-COOKIE-1, read out of the X authority file",
              ],
              [
                "keyboard",
                "libxkbcommon loaded at runtime, for correct layouts",
                <code>GetKeyboardMapping</code>,
              ],
              [
                "pointer shapes",
                <code>cursor-shape-v1</code>,
                "the cursor font",
              ],
              [
                "HiDPI",
                "follows output scale, integer only",
                "does not follow output scale — X11 has no protocol for it",
              ],
              [
                "decorations",
                "server-side when the compositor offers them",
                "whatever the window manager does",
              ],
              [
                "fullscreen",
                "asks and is told",
                <>
                  asks through <code>_NET_WM_STATE</code> rather than being able
                  to insist
                </>,
              ],
              [
                "layer surfaces",
                <code>zwlr_layer_shell_v1</code>,
                "no equivalent; refused with a message",
              ],
            ]}
          />
        ),
      },
      {
        id: "the-seam",
        title: "The seam",
        body: () => (
          <>
            <p>
              <code>window.odin</code> is the backend seam — geometry, the pixel
              store, input and window controls — with{" "}
              <code>wayland.odin</code> and <code>x11.odin</code> behind it, and
              the input model, frame pacing and resize handling shared rather
              than duplicated.
            </p>
            <p>
              Everything above the seam — the rasterizer, flexbox, the class
              parser, text shaping, the glyph cache, the widget set — is
              ordinary arithmetic over a pixel buffer and has no idea what a
              compositor is. That is why{" "}
              <Link to="/palmframe/beyond-linux">adding a third backend</Link> is
              adding a file rather than restructuring, and it is the part of the
              Palmframe plan that has already been paid for.
            </p>
          </>
        ),
      },
      {
        id: "exercising-x11",
        title: "Exercising X11",
        body: () => (
          <>
            <p>
              There is a script that runs the X11 backend end to end on a
              private Xvfb — window, properties, pixels against the offscreen
              renderer, keyboard, pointer, resize and the close handshake —
              without putting a window on your screen.
            </p>
            <CodeBlock lang="bash" code={`bash apps/tools/x11-selftest.sh`} />
            <p>
              The backend checks its screen rather than trusting it: it needs a
              little-endian, 32-bits-per-pixel TrueColor visual, which is every
              desktop X server since the 1990s, and it says so instead of
              drawing garbage when it is not.
            </p>
          </>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "offscreen-and-testing",
    title: "Offscreen rendering and testing",
    description:
      "The whole UI runs without a compositor, which is how palmy tests itself and how every screenshot on this site was made.",
    lead: () => (
      <Lede>
        The whole UI runs without a compositor. Layout, paint, hit testing and
        input all work with no display server in the environment, which is how
        palmy tests itself.
      </Lede>
    ),
    sections: [
      {
        id: "a-render",
        title: "A render",
        body: () => (
          <>
            <CodeBlock
              lang="odin"
              code={`off := palmy.offscreen_create(800, 600)
defer palmy.offscreen_destroy(off)

ui := palmy.offscreen_begin(off)
palmy.text(ui, "Hello", "text-2xl font-bold")
palmy.offscreen_end(off)

palmy.offscreen_write_png(off, "shot.png")`}
            />
            <p>
              <code>offscreen_create</code> takes a scale and a root class as
              well, so a render can be at 2&times; or on a different
              background.{" "}
              <code>offscreen_pixels</code>, <code>offscreen_canvas</code> and{" "}
              <code>offscreen_pixel</code> reach the buffer directly, and{" "}
              <code>offscreen_viewport</code> changes the size the tree is laid
              out against without reallocating.
            </p>
          </>
        ),
      },
      {
        id: "synthetic-input",
        title: "Synthetic input",
        body: () => (
          <>
            <p>
              Input can be driven, so interaction is assertable and not just
              layout.
            </p>
            <CodeBlock
              lang="odin"
              code={`palmy.move_pointer(off, 120, 64)
palmy.press(off)            // or .Right, .Middle
palmy.release(off)
palmy.scroll_by(off, 0, -120)
palmy.type_text(off, "hello")
palmy.press_key(off, palmy.KEY_RETURN)`}
            />
            <p>
              Combined with <code>node_rect</code>, that is a complete test: lay
              out a tree, find where a button landed, click there, render again
              and assert on what changed.
            </p>
            <CodeBlock
              lang="odin"
              code={`ui := palmy.offscreen_begin(off)
at := palmy.node_count(ui)
clicked := palmy.button(ui, "Save")
palmy.offscreen_end(off)

r := palmy.node_rect(ui, at)
palmy.move_pointer(off, r.x + r.w / 2, r.y + r.h / 2)
palmy.press(off)
palmy.release(off)
// next frame: clicked is true`}
            />
          </>
        ),
      },
      {
        id: "recording-a-demo",
        title: "Recording a demo",
        body: () => (
          <>
            <p>
              For a real window rather than an offscreen render, there is a
              recorder that takes a plain-text script.
            </p>
            <CodeBlock
              lang="text"
              title="demo.txt"
              code={`wait 0.6
type doc
wait 0.8
key Down
key Return`}
            />
            <p>
              Steps are <code>key &lt;name&gt;</code>,{" "}
              <code>chord &lt;mods&gt;+&lt;key&gt;</code>,{" "}
              <code>type &lt;text&gt;</code>,{" "}
              <code>move &lt;x&gt; &lt;y&gt;</code>,{" "}
              <code>click [button]</code> and <code>wait &lt;seconds&gt;</code>.
            </p>
            <Callout kind="tip" title="It records on a private compositor">
              <p>
                The recorder starts its own compositor with its own Wayland
                socket, its own virtual output at the size you ask for, and its
                own seat. Nothing appears on the user&rsquo;s screen, there is
                one window on that seat so keystrokes cannot land in somebody
                else&rsquo;s application, no focus can be stolen mid-take, and
                several of these can run at once because there is no shared
                lock.
              </p>
              <p>
                That is not a convenience. The problems it fixes were all real:
                one agent&rsquo;s recording capturing another&rsquo;s window,
                keystrokes arriving in the wrong application, crash toasts in
                frame, and a shared lock an orphaned process could hold for half
                an hour. All of them came from sharing one seat.
              </p>
            </Callout>
          </>
        ),
      },
      {
        id: "one-residual",
        title: "One residual",
        body: () => (
          <Callout kind="warn">
            <p>
              Each synthetic typing invocation attaches a fresh virtual keyboard
              and starts sending immediately, racing the compositor&rsquo;s
              delivery of focus, so an invocation&rsquo;s{" "}
              <strong>first keystroke is occasionally dropped</strong>. That is
              not a palmy bug — a terminal emulator loses it the same way on the
              same seat — and a priming keypress made it worse rather than
              better. If a step must not lose its first character, put a
              throwaway key before it.
            </p>
          </Callout>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "parity",
    title: "Measured against a browser",
    description:
      "All 61 shadcn/ui components rendered twice — once by Chromium from the real React source, once by palmy — and diffed per component.",
    lead: () => (
      <Lede>
        The font metrics, the subpixel glyph positioning, the linear-light
        coverage blending and the design-token system in this library were each
        a measurement, not a guess. This is the instrument.
      </Lede>
    ),
    sections: [
      {
        id: "the-rig",
        title: "The rig",
        body: () => (
          <>
            <p>
              A test rig renders every component twice — once by Chromium from
              the real React source, once by palmy — and reports the difference
              per component. Both sides use the same four static TrueType faces
              with kerning and ligatures turned off, because stb_truetype only
              reads the plain <code>kern</code> table and leaving the browser
              features on would otherwise leave a systematic drift across every
              string.
            </p>
            <p>
              Geometry — size, padding, radius, colour — matches exactly on
              every implemented case, and the size column in the report is where
              that is visible.
            </p>
          </>
        ),
      },
      {
        id: "why-zero-is-not-reachable",
        title: "Why zero is not reachable",
        body: () => (
          <>
            <p>
              Chromium rasterises glyphs through FreeType with its own hinting
              and gamma; palmy uses stb_truetype with grayscale coverage. A mean
              absolute error of 0 is therefore not achievable, and the residual
              is glyph antialiasing rather than anything structural. Colour,
              layout and geometry <em>can</em> match exactly, and they do.
            </p>
            <p>
              Two bugs the rig found are worth naming, because they are the kind
              that no amount of looking at a screenshot catches: a transparent
              border painted over a background because{" "}
              <code>background-clip</code> was not implemented, which moved the
              mean error from 3.94 to 3.13; and a fast path in the rounded-rect
              stroke that assumed straight sides and erased the corner arcs of
              any large radius, so a circular ring drew only two columns.
            </p>
          </>
        ),
      },
      {
        id: "reading-it",
        title: "Reading it per component",
        body: () => (
          <p>
            Every component page on this site carries its own measured cases —
            the pixel dimensions, the mean absolute error and the share of
            pixels within 2/255. Start at{" "}
            <Link to="/components">the component index</Link>.
          </p>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "limitations",
    title: "What is not here",
    description:
      "Honest limitations, not a roadmap. Read this before choosing the toolkit for something.",
    lead: () => (
      <Lede>
        Honest limitations, not a roadmap. Nothing on this list is a bug report
        waiting to happen; they are known, and several of them are deliberate.
      </Lede>
    ),
    sections: [
      {
        id: "the-list",
        title: "The list",
        body: () => (
          <ul>
            <li>
              <strong>Linux only.</strong> No macOS, no Windows. The{" "}
              <Link to="/palmframe/beyond-linux">plan</Link> for that is a plan.
            </li>
            <li>
              <strong>The X11 backend needs a little-endian,
              32-bits-per-pixel TrueColor screen</strong> — every desktop X
              server since the 1990s, but it checks and says so rather than
              drawing garbage. It does not follow output scale, has no
              layer-shell equivalent, and asks the window manager for fullscreen
              rather than being able to insist.
            </li>
            <li>
              <strong>Software rendering.</strong> Fine for interfaces at any
              size; a per-pixel effect over a 4K window is CPU work and will
              show it.
            </li>
            <li>
              <strong>One window per process.</strong> No popups, menus or
              tooltips — <code>xdg_popup</code> is not implemented, so anything
              overlaying is drawn inside the window.
            </li>
            <li>
              <strong>No clipboard, drag and drop, or input methods.</strong> No
              preedit, so CJK input will not work.
            </li>
            <li>
              <strong>Text is laid out left to right</strong> with simple word
              wrapping. No bidi and no complex shaping: missing glyphs come from
              a fallback chain, but there is no GSUB, so Arabic and Indic
              scripts are unjoined and emoji ZWJ sequences render as their parts.
            </li>
            <li>
              <strong>Integer output scale only.</strong> No fractional scaling
              protocol.
            </li>
            <li>
              <strong>Flexbox, not grid.</strong> No{" "}
              <code>align-content</code> for multi-line, no{" "}
              <code>min-content</code> or <code>max-content</code> keywords, no
              media queries.
            </li>
            <li>
              <strong>Grayscale antialiasing</strong>, no subpixel rendering.
            </li>
          </ul>
        ),
      },
      {
        id: "what-this-means-in-practice",
        title: "What this means in practice",
        body: () => (
          <p>
            The absence of popups is the one that changes how you write an
            application, and it is why several components in{" "}
            <Link to="/components">the component reference</Link> are marked
            partial: the panel exists and is measured, and where it goes is
            yours. The absence of media queries matters less than it sounds,
            because flexbox plus the real window size each frame is enough to
            lay out responsively — you branch on{" "}
            <code>palmy.size(ui)</code> instead of writing a breakpoint.
          </p>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "source-layout",
    title: "Layout of the source",
    description: "What each file in the toolkit is responsible for.",
    lead: () => (
      <Lede>
        Twenty-two files. Everything below the backend seam is two of them;
        everything above it has no idea what a compositor is.
      </Lede>
    ),
    sections: [
      {
        id: "files",
        title: "Files",
        body: () => (
          <DataTable
            head={["File", ""]}
            rows={[
              [
                <code>wire.odin</code>,
                "the shared socket: framing, Wayland encoding, fd passing",
              ],
              [
                <code>window.odin</code>,
                "the backend seam: geometry, the pixel store, input, controls",
              ],
              [
                <code>wayland.odin</code>,
                "registry, surfaces, shm pool, xdg-shell, layer-shell, seat",
              ],
              [
                <code>x11.odin</code>,
                "X11 core protocol: setup, window, MIT-SHM, events, cursors",
              ],
              [
                <code>xauth.odin</code>,
                "authority-file parsing for MIT-MAGIC-COOKIE-1",
              ],
              [
                <code>xkb.odin</code>,
                "keymaps: libxkbcommon on Wayland, GetKeyboardMapping on X11",
              ],
              [<code>canvas.odin</code>, "the rasterizer"],
              [
                <code>font.odin</code>,
                "font discovery, the family × weight × slant axes, glyph cache, measurement, drawing",
              ],
              [
                <code>outline.odin</code>,
                "dilating a glyph's coverage mask, for stroked text",
              ],
              [
                <code>emoji.odin</code>,
                "CBDT/CBLC colour bitmaps, which no vector rasterizer can draw",
              ],
              [
                <>
                  <code>color.odin</code>, <code>palette.odin</code>
                </>,
                "colours and the Tailwind palette",
              ],
              [<code>class.odin</code>, "the class parser"],
              [<code>node.odin</code>, "the element tree, identity, state"],
              [<code>layout.odin</code>, "flexbox"],
              [<code>paint.odin</code>, "tree to pixels"],
              [<code>app.odin</code>, "the frame loop, hit testing, input routing"],
              [<code>widgets.odin</code>, "the widget set"],
              [
                <code>offscreen.odin</code>,
                "rendering and input without a compositor",
              ],
              [
                <code>icon.odin</code>,
                "SVG path parsing and stroking, for line icons",
              ],
              [
                <code>theme.odin</code>,
                "design tokens, so class names can follow a design system",
              ],
              [<code>image.odin</code>, "decoding, fitting and sampling bitmaps"],
            ]}
          />
        ),
      },
    ],
  },
];
