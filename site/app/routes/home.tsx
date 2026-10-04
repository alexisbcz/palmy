import { Link } from "react-router";
import { ArrowRightIcon } from "lucide-react";
import { SiteFooter, SiteHeader } from "~/components/shell";
import { CodeBlock } from "~/components/code-block";
import { Callout, StatusBadge } from "~/components/bits";
import { Shot } from "~/components/shot";
import { COMPONENTS, PARITY_SUMMARY } from "~/content/components";
import { APPS } from "~/content/apps";

export function meta() {
  return [
    { title: "Palmframe — a Linux distribution with its own UI toolkit" },
    {
      name: "description",
      content:
        "palmy is a UI toolkit written from scratch in Odin: Wayland and X11 hand-rolled, a software rasterizer, flexbox, and Tailwind class strings. Palmframe is the distribution being built on it.",
    },
  ];
}

const HERO = `for ui in palmy.frames(app) {
	palmy.div(ui, "flex-col items-center justify-center w-full h-full gap-4 bg-slate-950")
	defer palmy.end(ui)

	palmy.textf(ui, "text-5xl font-bold text-white", "%d", count)

	if palmy.button(ui, "Add one", "bg-indigo-500 hover:bg-indigo-400 border-indigo-400") {
		count += 1
	}
}`;

function Pill({ children }: { children: React.ReactNode }) {
  return (
    <span className="rounded-full border bg-muted/40 px-2.5 py-1 font-mono text-[11px] text-muted-foreground">
      {children}
    </span>
  );
}

function Feature({
  title,
  children,
  to,
}: {
  title: string;
  children: React.ReactNode;
  to: string;
}) {
  return (
    <Link
      to={to}
      className="group flex flex-col gap-2 rounded-xl border p-5 transition hover:bg-accent/40"
    >
      <span className="flex items-center gap-1.5 font-medium">
        {title}
        <ArrowRightIcon className="size-3.5 -translate-x-1 opacity-0 transition group-hover:translate-x-0 group-hover:opacity-100" />
      </span>
      <span className="text-sm leading-6 text-muted-foreground">
        {children}
      </span>
    </Link>
  );
}

export default function Home() {
  return (
    <div className="min-h-screen">
      <SiteHeader />

      <main>
        {/* Hero ------------------------------------------------------------ */}
        <section className="mx-auto max-w-[1600px] px-4 pt-12 pb-16 lg:px-6 lg:pt-20">
          <div className="grid items-start gap-10 lg:grid-cols-2">
            <div className="min-w-0 max-w-xl">
              <div className="mb-5 flex flex-wrap items-center gap-2">
                <StatusBadge status="built" label="Toolkit: built, measured" />
                <StatusBadge
                  status="planned"
                  label="Distribution: a plan"
                />
              </div>
              <h1 className="text-4xl font-bold tracking-tight sm:text-5xl">
                A UI toolkit with a three-line dependency list.
              </h1>
              <p className="mt-5 text-lg leading-8 text-muted-foreground">
                <strong className="text-foreground">palmy</strong> is written
                from scratch in Odin. It speaks Wayland and X11 directly — both
                hand-rolled — rasterizes its own antialiased shapes and real
                TrueType glyphs, lays out with flexbox, and styles with Tailwind
                class strings.
              </p>
              <p className="mt-4 text-base leading-7 text-muted-foreground">
                <strong className="text-foreground">Palmframe</strong> is the
                distribution being built on it, for a machine where AI is part
                of the system rather than a website you visit. That half is a
                plan, and every page of it says so.
              </p>

              <div className="mt-7 flex flex-wrap gap-3">
                <Link
                  to="/docs/introduction"
                  className="inline-flex items-center gap-2 rounded-lg bg-foreground px-4 py-2 text-sm font-medium text-background transition hover:opacity-90"
                >
                  Read the docs
                  <ArrowRightIcon className="size-4" />
                </Link>
                <Link
                  to="/components"
                  className="inline-flex items-center gap-2 rounded-lg border px-4 py-2 text-sm font-medium transition hover:bg-accent"
                >
                  Browse {COMPONENTS.length} components
                </Link>
              </div>

              <div className="mt-8">
                <p className="mb-2 text-xs text-muted-foreground">
                  <code>ldd</code> on a palmy binary, in full:
                </p>
                <div className="flex flex-wrap gap-2">
                  <Pill>linux-vdso.so.1</Pill>
                  <Pill>libm.so.6</Pill>
                  <Pill>libc.so.6</Pill>
                </div>
              </div>
            </div>

            <div className="min-w-0 space-y-4">
              <CodeBlock lang="odin" code={HERO} />
              <Shot
                names={["gallery", "components", "hero", "widgets"]}
                alt="The widget gallery, rendered by palmy"
                aspect="16 / 10"
                note="Gallery capture not generated yet"
              />
            </div>
          </div>
        </section>

        {/* Numbers --------------------------------------------------------- */}
        <section className="border-y bg-muted/30">
          <div className="mx-auto grid max-w-[1600px] grid-cols-2 gap-6 px-4 py-10 lg:grid-cols-4 lg:px-6">
            {[
              [String(PARITY_SUMMARY.captured), "cases diffed against Chromium"],
              [
                PARITY_SUMMARY.meanMae.toFixed(3),
                "mean absolute error, of 255",
              ],
              [
                String(PARITY_SUMMARY.sizeMismatches),
                "geometry mismatches",
              ],
              [String(APPS.length), "applications on the toolkit"],
            ].map(([value, label]) => (
              <div key={label}>
                <p className="font-mono text-3xl font-semibold tracking-tight">
                  {value}
                </p>
                <p className="mt-1 text-xs leading-5 text-muted-foreground">
                  {label}
                </p>
              </div>
            ))}
          </div>
        </section>

        {/* The toolkit ----------------------------------------------------- */}
        <section className="mx-auto max-w-[1600px] px-4 py-16 lg:px-6">
          <h2 className="text-2xl font-semibold tracking-tight">
            What is hand-rolled
          </h2>
          <p className="mt-2 max-w-2xl text-sm leading-7 text-muted-foreground">
            Not as a stunt. The distribution above it is not worth attempting on
            a stack you cannot see the bottom of, and each of these was
            calibrated by measurement rather than by eye.
          </p>
          <div className="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <Feature title="Both display protocols" to="/docs/backends">
              Wayland messages encoded onto a socket by hand with file
              descriptors in control messages, and the X11 core protocol framed
              on the same machinery. No libwayland, no libX11, no libxcb.
            </Feature>
            <Feature title="A software rasterizer" to="/docs/drawing">
              Antialiased rounded rectangles, borders, shadows, gradients and
              lines from signed distance fields, written straight into the
              buffer the compositor is about to show.
            </Feature>
            <Feature title="Flexbox" to="/docs/the-frame-loop">
              The subset real interfaces use, close enough to CSS that a browser
              is a reliable mental model — including the automatic minimum size
              that makes a scrolling column overflow instead of squashing.
            </Feature>
            <Feature title="Tailwind classes" to="/docs/classes">
              The class names you already know, resolving against the real
              palette, with <code>hover:</code>, <code>active:</code>,{" "}
              <code>focus:</code> and <code>disabled:</code> variants and
              registered design tokens.
            </Feature>
            <Feature title="Real TrueType" to="/docs/text">
              Kerning, word wrap, a genuine italic axis, tabular figures,
              stroked glyph outlines, colour-bitmap emoji read out of the font
              tables, and a glyph cache.
            </Feature>
            <Feature title="Offscreen everything" to="/docs/offscreen-and-testing">
              The whole UI runs with no compositor at all, with synthetic input
              and queryable geometry, which is how it tests itself and how every
              screenshot here was made.
            </Feature>
          </div>
        </section>

        {/* Palmframe ------------------------------------------------------- */}
        <section className="border-t bg-muted/30">
          <div className="mx-auto max-w-[1600px] px-4 py-16 lg:px-6">
            <div className="flex flex-wrap items-center gap-3">
              <h2 className="text-2xl font-semibold tracking-tight">
                Palmframe
              </h2>
              <StatusBadge status="planned" label="A plan, not a shipped thing" />
            </div>
            <p className="mt-2 max-w-2xl text-sm leading-7 text-muted-foreground">
              The assistant on most machines today is a browser tab. It cannot
              see your files, cannot act on your mail, and forgets you between
              sessions. The alternative usually offered is worse: hand
              everything to one vendor and hope.
            </p>
            <div className="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
              <Feature
                title="AI as part of the system"
                to="/palmframe/ai-in-the-system"
              >
                A model running locally, as a user process, with the
                system&rsquo;s own applications built to be addressed by it. Two
                pieces of this exist already.
              </Feature>
              <Feature
                title="One account, several identities"
                to="/palmframe/identities"
              >
                Sub-identities with their own mail, files, credentials and
                assistant scope — where the useful version of the claim is the
                one with an assertion behind it.
              </Feature>
              <Feature title="One command surface" to="/palmframe/palm-cli">
                Every application fully operable from the command line, with a
                machine-readable schema, declared side-effect classes, and a
                scope rule that can only narrow.
              </Feature>
            </div>
            <div className="mt-6">
              <Callout kind="planned" title="Where the line is">
                <p>
                  The toolkit is measured against a browser and has a test
                  suite. The distribution does not. Pages in the Palmframe half
                  of this site carry a{" "}
                  <StatusBadge status="planned" className="align-middle" />{" "}
                  badge, and the sidebar marks them too, so a plan is never
                  quietly presented as a feature.
                </p>
              </Callout>
            </div>
          </div>
        </section>

        {/* Applications ---------------------------------------------------- */}
        <section className="mx-auto max-w-[1600px] px-4 py-16 lg:px-6">
          <div className="flex flex-wrap items-end justify-between gap-4">
            <div>
              <h2 className="text-2xl font-semibold tracking-tight">
                {APPS.length} applications
              </h2>
              <p className="mt-2 max-w-2xl text-sm leading-7 text-muted-foreground">
                A window manager that is itself a Wayland compositor. A mail
                stack that speaks IMAP in pure Odin. A word processor that
                writes its own <code>.docx</code>. A spreadsheet with its own
                formula engine. A BitTorrent client that refuses any address
                outside loopback.
              </p>
            </div>
            <Link
              to="/apps"
              className="inline-flex items-center gap-2 rounded-lg border px-4 py-2 text-sm font-medium transition hover:bg-accent"
            >
              See them all
              <ArrowRightIcon className="size-4" />
            </Link>
          </div>
          <ul className="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            {["wm", "files", "docs", "mail"].map((slug) => {
              const a = APPS.find((x) => x.slug === slug)!;
              return (
                <li
                  key={slug}
                  className="flex flex-col overflow-hidden rounded-xl border"
                >
                  <Shot
                    names={[`app-${a.slug}`, `apps-${a.slug}`, a.slug]}
                    alt={`${a.name}, rendered by palmy`}
                    aspect="16 / 10"
                    className="rounded-none border-0 border-b"
                  />
                  <div className="p-4">
                    <code className="text-sm font-semibold">{a.name}</code>
                    <p className="mt-1 text-sm leading-6 text-muted-foreground">
                      {a.summary}
                    </p>
                  </div>
                </li>
              );
            })}
          </ul>
        </section>
      </main>

      <SiteFooter />
    </div>
  );
}
