import { Link } from "react-router";
import { CodeBlock } from "~/components/code-block";
import { Callout, DataTable, Lede, StatusBadge } from "~/components/bits";
import type { DocPage } from "~/lib/doc";

const PLANNED = (
  <Callout kind="planned" title="This page describes a plan">
    <p>
      None of what follows is built. It is written down so the direction is on
      the record rather than implied, and it is marked as a plan on every page
      where it appears. The toolkit is measured against a browser and has a test
      suite; this does not.
    </p>
  </Callout>
);

export const PALMFRAME_DOCS: DocPage[] = [
  /* ---------------------------------------------------------------------- */
  {
    slug: "overview",
    title: "Palmframe",
    description:
      "An experiment in rethinking a Linux distribution for a machine where AI is part of the system rather than a website you visit.",
    lead: () => (
      <>
        <Lede>
          Palmframe is an experiment in rethinking a Linux distribution for a
          machine where AI is part of the system rather than a website you
          visit. <strong>palmy</strong> is its UI toolkit, and the toolkit came
          first because the rest is not worth attempting on a stack you cannot
          see the bottom of.
        </Lede>
      </>
    ),
    sections: [
      {
        id: "what-exists",
        title: "What exists today",
        body: () => (
          <>
            <div className="flex flex-wrap items-center gap-2">
              <StatusBadge status="built" label="Built and measured" />
            </div>
            <p>
              The toolkit, and the applications built on it: a window manager, a
              login manager, a file browser, a mail client, an office suite,
              media players, a torrent client, a local-model chat client, and
              others — forty of them.
            </p>
            <ul>
              <li>
                <Link to="/docs/introduction">palmy</Link>, a UI toolkit with a
                three-line dependency list, speaking Wayland and X11 both
                hand-rolled.
              </li>
              <li>
                <Link to="/components">61 widgets</Link> measured against
                Chromium rendering the real React source.
              </li>
              <li>
                <Link to="/apps">The applications</Link>, each with a scripted
                demo recorded on a private headless compositor.
              </li>
            </ul>
          </>
        ),
      },
      {
        id: "what-is-planned",
        title: "What is planned",
        body: () => (
          <>
            <div className="flex flex-wrap items-center gap-2">
              <StatusBadge status="planned" label="Written down, not built" />
            </div>
            <p>
              Everything in this half of the site. Saying so plainly is the
              point: a plan presented as a feature is the one failure mode a
              document like this has.
            </p>
            <DataTable
              head={["", "", ""]}
              rows={[
                [
                  <Link to="/palmframe/ai-in-the-system">
                    AI as part of the system
                  </Link>,
                  <StatusBadge status="planned" />,
                  "A local model the system's own applications are built to be addressed by.",
                ],
                [
                  <Link to="/palmframe/identities">
                    One account, several identities
                  </Link>,
                  <StatusBadge status="planned" />,
                  "Sub-identities with their own mail, files, credentials and assistant scope.",
                ],
                [
                  <Link to="/palmframe/cloud">The cloud part</Link>,
                  <StatusBadge status="planned" />,
                  "Postgres with row-level security as the enforcement point, files syncing rather than living remotely.",
                ],
                [
                  <Link to="/palmframe/palm-cli">
                    The <code>palm</code> command surface
                  </Link>,
                  <StatusBadge status="planned" />,
                  "One front door, designed for agents: a machine-readable schema and a scope rule.",
                ],
                [
                  <Link to="/palmframe/beyond-linux">Beyond Linux</Link>,
                  <StatusBadge status="partial" label="Partly paid for" />,
                  "Windows, macOS, Android and iOS. The backend seam exists; no third backend does.",
                ],
                [
                  <Link to="/palmframe/the-web">The web as another backend</Link>,
                  <StatusBadge status="planned" />,
                  "WebAssembly into a canvas buffer, which is the operation the rasterizer already performs.",
                ],
                [
                  <Link to="/palmframe/devices">Devices</Link>,
                  <StatusBadge status="planned" />,
                  "Clipboard, application state, notifications, input and agent context, moving between devices.",
                ],
                [
                  <Link to="/palmframe/hard-parts">The hard parts</Link>,
                  <StatusBadge status="planned" />,
                  "Three tensions worth naming before they are discovered.",
                ],
              ]}
            />
          </>
        ),
      },
      {
        id: "the-premise",
        title: "The premise",
        body: () => (
          <>
            <p>
              The assistant on most machines today is a browser tab. It cannot
              see your files, cannot act on your mail, and forgets you between
              sessions — so the work of connecting it to your life falls to you,
              by copying and pasting. The alternative usually offered is worse:
              hand everything to one vendor and hope.
            </p>
            <p>
              Palmframe is an attempt at a third shape, and the design
              constraint that makes it interesting is <em>scope</em>. An
              assistant that can read your work mail should not silently also
              read your personal mail, and the way to guarantee that is not to
              ask it nicely.
            </p>
          </>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "ai-in-the-system",
    title: "AI as part of the system",
    description:
      "A model running locally as a user process, with the system's own applications built to be addressed by it.",
    planned: true,
    lead: () => (
      <>
        <Lede>
          A model runs locally, as a user process, and the system&rsquo;s own
          applications are built to be addressed by it — the mail client, the
          file browser, the calendar, the notes.
        </Lede>
        {PLANNED}
      </>
    ),
    sections: [
      {
        id: "the-two-pieces-that-exist",
        title: "The two pieces that exist",
        body: () => (
          <>
            <div className="flex flex-wrap items-center gap-2">
              <StatusBadge status="built" />
            </div>
            <p>
              Two applications are the first pieces of this, and they are built
              rather than planned. Both talk to a loopback address and nothing
              else.
            </p>
            <ul>
              <li>
                <strong>A local-model client.</strong> A desktop client for a
                model running on the machine, with a hand-rolled HTTP/1.1 client
                doing chunked and NDJSON framing, the socket kept entirely off
                the UI thread, and conversations stored as plain text. There is
                no remote endpoint in the binary.
              </li>
              <li>
                <strong>A model that joins a chat channel as a participant.</strong>{" "}
                A separate process that connects to the chat server as an
                ordinary client and answers mentions by streaming a reply into a
                message it keeps editing. It is a single-threaded loop
                alternating between two sockets, which is why nothing in it needs
                a mutex.
              </li>
            </ul>
            <p>
              Neither of those is the distribution. They are the shape of the
              thing being argued for: the assistant as a process on the machine,
              addressable by the same means everything else is.
            </p>
          </>
        ),
      },
      {
        id: "why-local-came-first",
        title: "Why local came first",
        body: () => (
          <>
            <div className="flex flex-wrap items-center gap-2">
              <StatusBadge status="planned" />
            </div>
            <p>
              If a model runs on a server and reasons over your mail, the server
              can read your mail. That is not a policy choice; it is arithmetic.
              A local model avoids it entirely, which is why the local one came
              first, and anything that later moves to a server has to be honest
              about which of the two it gave up.
            </p>
            <p>
              See <Link to="/palmframe/hard-parts">The hard parts</Link>, where
              this is one of three tensions stated rather than resolved.
            </p>
          </>
        ),
      },
      {
        id: "addressability",
        title: "What addressable means",
        body: () => (
          <>
            <div className="flex flex-wrap items-center gap-2">
              <StatusBadge status="planned" />
            </div>
            <p>
              An assistant that can only see a screenshot of your mail client is
              not integrated; it is squinting. The plan is that every
              application is a library with two front ends — the window and the
              command line — over one implementation, so there is nothing for
              the two to disagree about.
            </p>
            <p>
              That is what{" "}
              <Link to="/palmframe/palm-cli">
                the <code>palm</code> command surface
              </Link>{" "}
              is for, and it is also where the scope rule is enforced, because
              it is the only door.
            </p>
          </>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "identities",
    title: "One account, several identities",
    description:
      "A person is not one identity. The plan is a single account that owns several sub-identities, each with its own assistant scope.",
    planned: true,
    lead: () => (
      <>
        <Lede>
          There is the work self, the personal self, the one that deals with
          public-facing accounts, sometimes one for a side project or a company.
          Today each lives in a separate browser profile, a separate mail
          client, a separate password store.
        </Lede>
        {PLANNED}
      </>
    ),
    sections: [
      {
        id: "the-problem",
        title: "The problem with doing it by hand",
        body: () => (
          <p>
            The separation is entirely manual, and it holds right up until you
            paste the wrong thing into the wrong window. Friction is doing the
            security work, which means the separation is a convention rather
            than a boundary — and conventions fail at exactly the moment they
            matter.
          </p>
        ),
      },
      {
        id: "sub-identities",
        title: "Sub-identities",
        body: () => (
          <>
            <p>
              A single Palmframe account owns several sub-identities, each with
              its own mail, files, credentials, browsing state, and its own
              assistant scope. Switching between them is a first-class
              operation, not a matter of remembering which window you are in.
            </p>
            <p>
              They can be <strong>explicitly linked</strong> where that is
              useful — the same person, with the same calendar availability
              across work and personal, able to move a file deliberately from
              one to another — and the link is explicit and auditable rather
              than ambient.
            </p>
          </>
        ),
      },
      {
        id: "the-testable-version",
        title: "The testable version",
        body: () => (
          <>
            <Callout kind="note" title="The standard this has to meet">
              <p>
                Identity separation is easy to claim and hard to prove. The
                useful version is testable: an assistant scoped to one identity,
                asked for something from another, should fail — and there should
                be an assertion somewhere that says so and <em>runs</em>.
              </p>
            </Callout>
            <p>
              That assertion does not exist yet. The design for where it would
              live does:
            </p>
            <CodeBlock
              lang="bash"
              code={`PALM_IDENTITY=work palm mail list --json      # work mail
PALM_IDENTITY=work palm mail list --identity personal
# exit 5, {"error":"out of scope","identity":"work","requested":"personal"}`}
            />
            <p>
              Scope is read from the environment and may only ever be{" "}
              <em>narrowed</em> by a flag, never widened. A process started
              inside a scope cannot escape it by asking nicely, which is the only
              version of this that means anything.
            </p>
          </>
        ),
      },
      {
        id: "the-sharpest-case",
        title: "The sharpest case",
        body: () => (
          <p>
            Credentials. A secret would be returned only to a caller already
            inside the owning identity&rsquo;s scope, every access written to an
            audit log with the caller&rsquo;s identity, and there would be no
            verb that lists secrets across identities at all — not gated,
            absent. A capability that exists and is guarded is a capability
            someone will find a way to invoke.
          </p>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "cloud",
    title: "The cloud part",
    description:
      "Postgres with row-level security as the enforcement point, and files that sync rather than live remotely.",
    planned: true,
    lead: () => (
      <>
        <Lede>
          Supabase is the intended backend: Postgres, auth, storage and
          row-level security.
        </Lede>
        {PLANNED}
      </>
    ),
    sections: [
      {
        id: "the-load-bearing-piece",
        title: "The load-bearing piece",
        body: () => (
          <>
            <p>
              Row-level security is the part that matters, because separation
              between identities has to be <strong>enforced by the database</strong>,
              not by which panel the file browser happens to be showing.
            </p>
            <p>
              A boundary that exists only in the interface is not a boundary; it
              is a convention, and conventions fail at exactly the moment they
              matter.
            </p>
          </>
        ),
      },
      {
        id: "local-first",
        title: "Local-first",
        body: () => (
          <p>
            Files sync rather than live remotely, so the machine works unplugged
            and the cloud is where state converges rather than where it is held
            hostage. That ordering is also what makes the applications testable:
            every one of them today reads and writes real files on disk, and
            several — the notebook, the mail client — deliberately use plain
            formats so another tool can open them.
          </p>
        ),
      },
      {
        id: "the-threat-model",
        title: "The part that needs a written threat model",
        body: () => (
          <Callout kind="warn">
            <p>
              A single account is a single point of compromise. Consolidating a
              person&rsquo;s computing life into one login makes that login the
              most valuable credential they own. The standard to meet is a
              written threat model that states what is and is not protected — an
              attacker with the stored data and no password is a very different
              adversary from one who can read process memory — and an answer to{" "}
              <em>what happens when this is phished?</em> that is not a shrug.
            </p>
            <p>That document does not exist yet either.</p>
          </Callout>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "palm-cli",
    title: "The palm command surface",
    description:
      "One CLI through which a coding agent can operate every part of the system, with a machine-readable schema and declared side-effect classes.",
    planned: true,
    lead: () => (
      <>
        <Lede>
          A single command surface through which a coding agent can operate
          every part of Palmframe: the window manager, the applications, the
          system state, and eventually the identity and cloud layer. Humans use
          it too, but they are the second audience.
        </Lede>
        {PLANNED}
      </>
    ),
    sections: [
      {
        id: "the-principle",
        title: "Every application is a library with two front ends",
        body: () => (
          <>
            <p>
              The GUI is one. The CLI is the other, and it is not a reduced
              version — anything a person can do in the window, an agent can do
              from a command, with the same code underneath.
            </p>
            <p>
              That is the opposite of wrapping. A wrapper re-implements a subset
              in shell and drifts from the real behaviour; two front ends over
              one core cannot drift, because there is only one implementation of
              what the application actually does.
            </p>
            <p>
              Several applications are already shaped this way without it being
              a policy. The mail engine is headless by construction — it is an
              engine, and the mail GUI is a separate program reading the Maildir
              it writes. The spreadsheet keeps its formula engine apart from the
              grid. The word processor separates its model and its layout from
              its UI, which is why it can produce a PDF with no window open.
            </p>
          </>
        ),
      },
      {
        id: "the-inventory",
        title: "The inventory, honestly",
        body: () => (
          <>
            <p>
              Others are not shaped that way, and the flags each application
              invented for itself show it plainly.
            </p>
            <DataTable
              head={["", ""]}
              rows={[
                [
                  "rich already",
                  <code>
                    mailcore (33 flags), torrent (24), call (22), chat, docs,
                    money
                  </code>,
                ],
                [
                  "nearly nothing",
                  <code>maps, reader, shop, launcher, files, notes, calendar</code>,
                ],
              ]}
            />
            <p>
              And the conventions have diverged: <code>--selftest</code> against{" "}
              <code>--self-test</code> (one application accepts both),{" "}
              <code>--shot</code> against <code>--export-png</code>,{" "}
              <code>--help</code> present in about a dozen of forty. Each was a
              reasonable local choice; together they are not a surface anything
              can be built on.
            </p>
            <p>
              So the work is two things, and the second is the larger: a shared
              convention, and then every application brought up to it.
            </p>
          </>
        ),
      },
      {
        id: "what-an-agent-needs",
        title: "What an agent needs that a person does not",
        body: () => (
          <>
            <ul>
              <li>
                <strong>Structured results, not just a structured index.</strong>{" "}
                Every command takes <code>--json</code> and emits a documented
                object. <code>palm audio status --json</code> returns sinks and
                volumes; it does not return <code>Volume is now 40%</code>.
              </li>
              <li>
                <strong>A machine-readable surface.</strong>{" "}
                <code>palm schema</code> emits the entire command tree as JSON —
                nouns, verbs, argument types, enumerated values, the output
                schema and the side-effect class — so an agent can plan from it
                instead of discovering commands by trial.
              </li>
              <li>
                <strong>Refusal instead of prompting.</strong> A destructive
                command without <code>--yes</code> exits non-zero with a
                machine-readable reason. It never blocks on a TTY read, which is
                how agent pipelines hang.
              </li>
              <li>
                <strong>
                  <code>--dry-run</code> on everything that mutates
                </strong>
                , printing the same JSON the real run would, plus what it would
                change.
              </li>
            </ul>
            <p>
              The reason prose output is not enough is narrower than it looks:
              an index of commands can be structured while the commands
              themselves print English, and an agent then parses English, which
              is where agent tooling usually starts failing — quietly, on the day
              a message changes.
            </p>
          </>
        ),
      },
      {
        id: "side-effect-classes",
        title: "A declared side-effect class per command",
        body: () => (
          <>
            <p>
              The useful question before running something is <em>can I retry
              this, and what does it touch</em>.
            </p>
            <DataTable
              head={["Class", "Meaning"]}
              rows={[
                [<code>read</code>, "no state changes; always safe"],
                [
                  <code>idempotent</code>,
                  "converges on a state; safe to repeat",
                ],
                [
                  <code>mutate</code>,
                  "changes state; repeating is not the same as running once",
                ],
                [
                  <code>destructive</code>,
                  <>
                    loses data or is hard to undo; refuses without{" "}
                    <code>--yes</code>
                  </>,
                ],
                [
                  <code>intent</code>,
                  "deliberately does nothing but log what it would have done",
                ],
              ]}
            />
            <Callout kind="note" title="intent is not a joke">
              <p>
                Power and session actions in this project already behave that
                way. The power applet logs the command it would run and executes
                nothing, so a demo script driving the UI cannot reboot the
                machine. The network applet does the same after a live command
                could have taken the machine off the network — and with it the
                session doing the work. <code>palm</code> keeps that property
                rather than quietly becoming the way around it.
              </p>
            </Callout>
          </>
        ),
      },
      {
        id: "exit-codes",
        title: "Stable exit codes",
        body: () => (
          <CodeBlock
            lang="text"
            copy={false}
            code={`0  ok
2  usage error
3  not found
4  refused: needs --yes
5  refused: out of scope for this identity
6  unavailable: the thing it talks to is not running
7  failed`}
          />
        ),
      },
      {
        id: "the-surface",
        title: "The surface",
        body: () => (
          <>
            <p>Nouns follow the system, not the source tree.</p>
            <CodeBlock
              lang="text"
              code={`palm app        list | info | launch | kill
palm window     list | focus | move | resize | fullscreen | close
palm workspace  list | switch | move-window
palm theme      list | get | set | tokens
palm display    list | info | scale
palm audio      status | output | input | volume | mute
palm net        status | wifi list                 # read-only, see below
palm power      status | lock | suspend | reboot   # intent class
palm capture    screenshot | record                # headless by default
palm notify     send | list | dismiss

palm mail       folders | list | read | search | compose | send
palm files      list | stat | find | open
palm notes      list | read | write | search
palm calendar   list | add | next
palm vault      list | get | add                   # scoped
palm money      accounts | import | budget
palm reader     library | open | position
palm torrent    list | add | pause | remove
palm ai         models | prompt | scope

palm identity   list | current | switch | link | scope
palm dev        build | test | parity | record | lint
palm schema     the whole surface as JSON
palm commands   the command index`}
            />
          </>
        ),
      },
      {
        id: "safety-rules",
        title: "Safety rules that live in the code, not the docs",
        body: () => (
          <>
            <p>
              This project has already made these decisions in several places,
              and the command surface must not become the hole in them.
            </p>
            <ul>
              <li>
                <strong>Networking is read-only.</strong> There is no verb that
                disables the radio or drops a connection.
              </li>
              <li>
                <strong>
                  No enabling or disabling of the display manager or the model
                  server.
                </strong>{" "}
                The model is deliberately a user process here.
              </li>
              <li>
                <strong>Power and session actions are intent class</strong> and
                log what they would run.
              </li>
              <li>
                <strong>Camera and microphone are never captured.</strong>{" "}
                Synthetic sources only, which is what every demo in this
                repository already uses.
              </li>
              <li>
                <strong>Capture records on a private headless compositor</strong>{" "}
                by default, so an agent filming a demo cannot put a window on
                the user&rsquo;s screen or type into their session. The flaw
                that motivated this is documented: a shared compositor meant one
                agent&rsquo;s keystrokes landed in another&rsquo;s window and
                added slides to its deck.
              </li>
            </ul>
          </>
        ),
      },
      {
        id: "testability",
        title: "Testability",
        body: () => (
          <>
            <p>
              The surface being machine-readable makes the CLI testable in a way
              prose is not.
            </p>
            <ul>
              <li>
                <code>palm schema</code> is itself asserted — every command it
                advertises exists, every example it ships parses, and every
                documented exit code is produced by something.
              </li>
              <li>
                Every <code>read</code> command runs in CI and must emit JSON
                matching its declared schema.
              </li>
              <li>
                Every <code>destructive</code> command is asserted to refuse
                without <code>--yes</code>, and the <code>intent</code> commands
                are asserted to execute nothing — the same trap the power applet
                already uses, with fake system binaries on the path writing to a
                sentinel file that must stay empty.
              </li>
              <li>The scope rule gets the assertion it needs.</li>
            </ul>
          </>
        ),
      },
      {
        id: "the-convention",
        title: "The shared convention",
        body: () => (
          <>
            <p>
              One implementation, in the shared kit, so forty applications
              cannot each invent their own. An application declares its
              commands; the kit parses, validates, generates <code>--help</code>
              , emits <code>--json</code>, honours <code>--dry-run</code> and
              produces the exit codes above. <code>palm schema</code> then
              introspects the same declarations, which is what keeps the index
              and the behaviour from drifting apart.
            </p>
            <CodeBlock
              lang="text"
              code={`--json          structured output on stdout, nothing else on stdout
--dry-run       for any mutating command
--yes           required by destructive commands
--help          generated from the declaration, never hand-written
--identity NAME narrow the scope, never widen it`}
            />
            <p>
              Two rules matter more than they look.{" "}
              <strong>
                Machine output goes to stdout and nothing else does
              </strong>{" "}
              — progress, warnings and prose go to stderr, so a pipeline never
              has to strip chatter out of a JSON document. And{" "}
              <strong>
                <code>--selftest</code> is the one existing convention to keep
              </strong>
              , since every application already has it and the counts are how
              this project has been judging its own work all along.
            </p>
          </>
        ),
      },
      {
        id: "bringing-forty-up-to-it",
        title: "Bringing forty applications up to it",
        body: () => (
          <>
            <p>
              The order is by what an agent would reach for first, not
              alphabetically.
            </p>
            <ol>
              <li>
                <strong>Already close.</strong> Mostly renaming flags onto the
                convention and adding <code>--json</code>.
              </li>
              <li>
                <strong>Have an engine but no CLI over it.</strong> The core is
                there; the commands are not.
              </li>
              <li>
                <strong>UI-shaped, needing a core to be lifted out.</strong>{" "}
                These are the real work, and lifting the core out is worth doing
                for its own sake: it is what makes them testable headlessly.
              </li>
              <li>
                <strong>System applets.</strong> Small surfaces, and the safety
                rules bite hardest here.
              </li>
            </ol>
            <p>
              A thing is done when the GUI uses the same entry points the CLI
              does. If writing a note from the command line goes through a
              different path than typing in the window, the two will diverge,
              and the CLI will be the one that rots.
            </p>
          </>
        ),
      },
      {
        id: "open-questions",
        title: "Open questions",
        body: () => (
          <ul>
            <li>
              <strong>How a long-running command reports progress</strong> to an
              agent. Streaming NDJSON on stdout is the obvious answer and
              matches what the local-model client already consumes.
            </li>
            <li>
              <strong>
                Whether the audit log is append-only on disk or in the account
              </strong>
              , once the account exists.
            </li>
            <li>
              <strong>
                Whether <code>palm</code> is a dispatcher of separate binaries
                or one binary with subcommands.
              </strong>{" "}
              Separate binaries keep each application independently runnable and
              testable, which is worth a lot here; the dispatcher then exists
              for discovery and scope enforcement rather than for routing alone.
            </li>
          </ul>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "beyond-linux",
    title: "Beyond Linux",
    description:
      "The intention is that all of this runs on Windows, macOS, Android and iOS. The backend seam has already paid part of the cost.",
    planned: true,
    lead: () => (
      <>
        <Lede>
          The X11 work has already paid part of the cost: the backend seam
          exists, with Wayland and X11 behind it and the input model, frame
          pacing and resize handling shared rather than duplicated. Adding a
          third backend is adding a file, not restructuring.
        </Lede>
        <Callout kind="planned" title="Partly paid for, not built">
          <p>
            The seam is real and you can read it —{" "}
            <Link to="/docs/backends">Wayland and X11</Link>. No third backend
            exists. Everything below about Windows, macOS, Android and iOS is a
            plan.
          </p>
        </Callout>
      </>
    ),
    sections: [
      {
        id: "the-tractable-half",
        title: "The tractable half",
        body: () => (
          <>
            <p>
              Everything above the seam — the rasterizer, flexbox, the class
              parser, text shaping, the glyph cache, the widget set — is
              ordinary arithmetic over a pixel buffer and has no idea what a
              compositor is. What each platform has to supply is small and well
              understood: a window, a buffer to blit into, and an input stream.
            </p>
            <DataTable
              head={["", "The surface to present into", "The input to read"]}
              rows={[
                [
                  "Windows",
                  <>
                    Win32 window, <code>StretchDIBits</code>
                  </>,
                  "the message loop",
                ],
                [
                  "macOS",
                  <>
                    <code>NSWindow</code> with a <code>CGImage</code> layer
                  </>,
                  "AppKit events",
                ],
                [
                  "Android",
                  <code>ANativeWindow_lock/unlockAndPost</code>,
                  <code>NativeActivity</code>,
                ],
                [
                  "iOS",
                  <>
                    <code>UIView</code> backed by a bitmap{" "}
                    <code>CALayer</code>
                  </>,
                  "UIKit events",
                ],
              ]}
            />
            <p>
              None of those needs a GPU, which is the whole reason a software
              rasterizer was worth writing.
            </p>
          </>
        ),
      },
      {
        id: "the-harder-half",
        title: "The applications are the harder half",
        body: () => (
          <>
            <Callout kind="warn" title="Worth stating now rather than discovering during a port">
              <p>
                Many applications reach for a Unix subprocess: a media
                transcoder, an archiver, audio and network control tools, a
                screen capturer, document renderers. On Windows and macOS those
                are a packaging problem. On iOS and Android they are not
                available at all — a sandboxed application cannot spawn a
                process, so anything built that way simply does not run.
              </p>
            </Callout>
            <p>
              That turns an abstract portability goal into a concrete discipline
              for work happening now:{" "}
              <strong>
                keep each application&rsquo;s core free of subprocess
                assumptions, and put the shelling-out behind a seam of its own.
              </strong>
            </p>
            <p>
              The mail engine is already the right shape — it parses MIME and
              speaks IMAP in pure Odin, and the GUI is a separate program. The
              word processor writes PDF, <code>.docx</code>, <code>.odt</code>{" "}
              and <code>.rtf</code> itself. Those port. An application whose only
              way to decode a video is to pipe through an external binary needs
              a decoding seam before it can move, and the time to notice that is
              while the code is being written.
            </p>
          </>
        ),
      },
      {
        id: "three-things-a-port-makes-unavoidable",
        title: "Three things a port makes unavoidable",
        body: () => (
          <ul>
            <li>
              <strong>Touch is not a mouse.</strong> Hit targets, scrolling,
              text selection and the absence of hover all differ. The
              responsive-layout work already done helps; the input model needs
              more than a rename.
            </li>
            <li>
              <strong>Mobile lifecycle is not desktop lifecycle.</strong> An
              application is suspended, resumed and killed by the system, so
              state has to survive being stopped at any moment — which is a
              better discipline on the desktop too.
            </li>
            <li>
              <strong>Font discovery is per-platform.</strong> The current scan
              walks Linux font directories; DirectWrite and CoreText answer the
              same question differently, and the fallback chain added for CJK
              needs an equivalent on each.
            </li>
          </ul>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "the-web",
    title: "The web as another backend",
    description:
      "A browser is a third entry in the backend table: WebAssembly, a canvas buffer, and the same rasterizer.",
    planned: true,
    lead: () => (
      <>
        <Lede>
          The shape of this is already decided by the shape of everything else.
          The backend seam has Wayland and X11 behind it; a browser is a third
          entry in that table.
        </Lede>
        {PLANNED}
      </>
    ),
    sections: [
      {
        id: "why-it-fits",
        title: "Why it fits",
        body: () => (
          <>
            <p>
              Odin targets WebAssembly, a <code>&lt;canvas&gt;</code> gives you
              an <code>ImageData</code> buffer, and writing pixels into that
              buffer is the same operation the rasterizer already performs
              against shared memory. The layout engine, the class parser, the
              text shaping, the glyph cache and the widget set do not change at
              all.
            </p>
            <p>
              That makes the web version of an application{" "}
              <em>the application</em>, not a reimplementation of it in another
              language that slowly disagrees with the original.
            </p>
          </>
        ),
      },
      {
        id: "the-constraints",
        title: "The constraints",
        body: () => (
          <>
            <p>
              They are the same ones mobile imposes, which is convenient: no
              subprocess, a sandboxed filesystem, a different lifecycle. Two are
              specific to the browser.
            </p>
            <ul>
              <li>
                <strong>Fonts cannot be discovered by scanning a directory</strong>
                , so they have to be shipped and fetched.
              </li>
              <li>
                <strong>Threads need Web Workers with SharedArrayBuffer</strong>
                , which needs the cross-origin isolation headers.
              </li>
            </ul>
            <p>
              Neither is novel, and both reinforce the same discipline: keep the
              core free of assumptions about having a Unix underneath it.
            </p>
          </>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "devices",
    title: "Devices that share one computing life",
    description:
      "Not file transfer. Clipboard, application state, notifications, input, media sessions and agent context, moving between devices.",
    planned: true,
    lead: () => (
      <>
        <Lede>
          Moving a file between two machines that happen to be near each other
          is a useful trick, and it is not the interesting problem. The
          interesting problem is that a person&rsquo;s devices are, between
          them, one computing life, and every operating system still treats them
          as strangers that occasionally exchange parcels.
        </Lede>
        {PLANNED}
      </>
    ),
    sections: [
      {
        id: "what-should-move",
        title: "What should move",
        body: () => (
          <ul>
            <li>
              <strong>Clipboard</strong>, continuously, scoped to an identity.
            </li>
            <li>
              <strong>Application state.</strong> A document with a cursor
              position, a video with a playhead, a half-written mail, a search
              you were in the middle of. Pick the phone up and it is there, at
              the same place.
            </li>
            <li>
              <strong>Notifications</strong>, once, on the device you are
              actually looking at, rather than on all of them.
            </li>
            <li>
              <strong>Input.</strong> One keyboard and pointer reaching across
              whatever screens are in front of you.
            </li>
            <li>
              <strong>Media sessions</strong>, so a call or a track moves to
              another device without stopping.
            </li>
            <li>
              <strong>Agent context.</strong> A conversation with the local
              model, and what it was working on, following you — which is the
              part none of the existing systems do at all, and the reason this is
              worth building rather than adopting.
            </li>
          </ul>
        ),
      },
      {
        id: "prior-art-here",
        title: "The transport has prior art in this repository",
        body: () => (
          <>
            <div className="flex flex-wrap items-center gap-2">
              <StatusBadge status="built" label="These two exist" />
            </div>
            <p>
              The calling application defines its own protocol over UDP with a
              24-byte header and a microsecond timestamp taken from the same
              monotonic clock on both ends, so one-way delay is a subtraction
              rather than a guess, with a jitter buffer measured at 33 ms end to
              end. The chat application runs a length-prefixed JSON protocol over
              TCP with a broadcast ordering guarantee.
            </p>
            <p>
              Device-to-device is the same kind of problem with harder
              discovery.
            </p>
          </>
        ),
      },
      {
        id: "the-shape",
        title: "The shape",
        body: () => (
          <>
            <p>
              Every device holds its own keypair and is enrolled into the
              account; discovery is mDNS on a shared network and the account
              registry otherwise; the transport is direct when the devices can
              reach each other and relayed when they cannot; and it is{" "}
              <strong>end-to-end encrypted in both cases</strong>.
            </p>
            <p>
              That last point is worth being precise about, because it is where
              this differs from{" "}
              <Link to="/palmframe/cloud">the cloud paragraph</Link>: a relay
              that only forwards opaque bytes needs no ability to read them, so
              device-to-device can be genuinely end-to-end even though a{" "}
              <em>server-side model</em> reasoning over your mail cannot be.
            </p>
          </>
        ),
      },
      {
        id: "two-things-to-get-right",
        title: "Two things to get right rather than discover",
        body: () => (
          <>
            <Callout kind="warn" title="Identity scoping applies to devices too">
              <p>
                A work document handing itself to a personal phone is a leak
                with a friendly animation. Crossing between identities should be
                a deliberate act, not an ambient convenience.
              </p>
            </Callout>
            <Callout
              kind="warn"
              title="Ambient state flow is a larger attack surface than file transfer"
            >
              <p>
                Every bullet above is a channel; each needs to be authenticated
                per device, revocable when a device is lost, and inspectable —{" "}
                <em>what has this device sent and received</em> should be a
                question with an answer.
              </p>
            </Callout>
          </>
        ),
      },
    ],
  },

  /* ---------------------------------------------------------------------- */
  {
    slug: "hard-parts",
    title: "The parts that are genuinely hard",
    description:
      "Four tensions stated rather than resolved, because discovering them later is worse.",
    planned: true,
    lead: () => (
      <>
        <Lede>
          These are worth naming now rather than discovering later. None of them
          has an answer in this repository yet.
        </Lede>
        {PLANNED}
      </>
    ),
    sections: [
      {
        id: "single-point-of-compromise",
        title: "A single account is a single point of compromise",
        body: () => (
          <p>
            Consolidating a person&rsquo;s computing life into one login makes
            that login the most valuable credential they own. The standard to
            meet is a written threat model that states what is and is not
            protected — an attacker with the stored data and no password is a
            very different adversary from one who can read process memory — and
            an answer to <em>what happens when this is phished?</em> that is not
            a shrug.
          </p>
        ),
      },
      {
        id: "server-ai-versus-e2e",
        title: "Server-side AI and end-to-end encryption pull against each other",
        body: () => (
          <p>
            If a model runs on a server and reasons over your mail, the server
            can read your mail — that is not a policy choice, it is arithmetic.
            Local models avoid it entirely, which is why{" "}
            <Link to="/palmframe/ai-in-the-system">the local one came first</Link>
            ; anything that moves to a server has to be honest about which of
            the two it gave up.
          </p>
        ),
      },
      {
        id: "separation-is-easy-to-claim",
        title: "Identity separation is easy to claim and hard to prove",
        body: () => (
          <p>
            The useful version is testable: an assistant scoped to one identity,
            asked for something from another, should fail — and there should be
            an assertion somewhere that says so and runs. That is the standard
            the rest of this repository is held to, and it is the one that
            matters most here.
          </p>
        ),
      },
      {
        id: "convenience-versus-leakage",
        title: "Convenience between devices is indistinguishable from leakage until you can say which is which",
        body: () => (
          <p>
            Everything in <Link to="/palmframe/devices">the devices section</Link>{" "}
            makes data move with less friction, and friction is doing some of the
            security work today. The answer is not less capability; it is that
            every channel is authenticated per device, revocable the moment one
            is lost, scoped to an identity, and logged well enough that{" "}
            <em>what did this device send</em> has an answer rather than a shrug.
          </p>
        ),
      },
    ],
  },
];
