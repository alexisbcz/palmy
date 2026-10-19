import { Link } from "react-router";
import { seo } from "~/lib/seo";
import { Shell } from "~/components/shell";
import { Callout, DataTable, StatusBadge, Ticks } from "~/components/bits";
import { componentsSidebar } from "~/lib/nav";
import {
  COMPONENTS,
  GAP_TEXT,
  PARITY_SUMMARY,
  STATUS_COUNTS,
  parityCasesFor,
} from "~/content/components";

export function meta() {
  return seo({
    title: "Components",
    description:
      "All 61 shadcn/ui components, the Odin that produces each one, and what the Odin version does and does not do.",
    path: "/components",
  });
}

const GAP_LABEL = {
  overlay: "Drawn in the window",
  fixture: "Geometry pinned to the measured case",
  input: "Caret and focus are the application's",
} as const;

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl border p-4">
      <p className="font-mono text-2xl font-semibold tracking-tight">{value}</p>
      <p className="mt-1 text-xs text-muted-foreground">{label}</p>
    </div>
  );
}

export default function ComponentsIndex() {
  const extras = COMPONENTS.filter((c) => c.extra);
  const partials = COMPONENTS.filter((c) => c.status === "partial");

  return (
    <Shell sidebar={componentsSidebar()} wide>
      <div className="mx-auto max-w-5xl">
        <header className="mb-8 space-y-3">
          <p className="text-xs text-muted-foreground">Components</p>
          <h1 className="text-3xl font-bold tracking-tight sm:text-4xl">
            The widget set
          </h1>
          <p className="max-w-2xl text-base leading-7 text-muted-foreground">
            Every component the shadcn CLI installs is here, including the ones
            this project does not use, because the point is partly to see what
            is available. Each page shows the Odin that produces it, the React
            equivalent, and what the Odin version does and does not do.
          </p>
        </header>

        <div className="mb-8 grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Stat label="components" value={String(COMPONENTS.length)} />
          <Stat
            label="cases measured against Chromium"
            value={String(PARITY_SUMMARY.captured)}
          />
          <Stat
            label="mean absolute error, of 255"
            value={PARITY_SUMMARY.meanMae.toFixed(3)}
          />
          <Stat
            label="layout mismatches"
            value={String(PARITY_SUMMARY.sizeMismatches)}
          />
        </div>

        <section className="mb-10 space-y-4">
          <h2 className="text-xl font-semibold tracking-tight">
            What the badges mean
          </h2>
          <p className="text-sm leading-7 text-muted-foreground">
            Pixels are not the axis that varies. All {COMPONENTS.length} are
            implemented as Odin widgets and all of them are measured against
            Chromium rendering the real React source, with{" "}
            <strong>{PARITY_SUMMARY.notImplemented} cases not implemented</strong>{" "}
            and {PARITY_SUMMARY.sizeMismatches} geometry mismatches. What varies
            is how much of each component the widget owns.
          </p>
          <DataTable
            head={["Badge", "Count", "Meaning"]}
            rows={[
              [
                <StatusBadge status="built" />,
                STATUS_COUNTS.built,
                "The widget is a widget. Hand it state and it is usable in an application.",
              ],
              [
                <StatusBadge status="partial" />,
                STATUS_COUNTS.partial,
                "It renders and is measured, but a named piece of the behaviour belongs to the caller. Each page says which piece.",
              ],
              [
                <StatusBadge status="absent" />,
                STATUS_COUNTS.absent,
                "Not implemented at all. There are none — and this row exists so that is stated rather than implied by omission.",
              ],
            ]}
          />
          <Callout kind="note" title="Why anything is partial">
            <p>
              Almost always for one reason: palmy does not implement{" "}
              <code>xdg_popup</code> and there is one window per process, so a
              floating panel is drawn inside the window rather than on a surface
              of its own. That is a documented{" "}
              <Link to="/docs/limitations">limitation of the toolkit</Link>, not
              an unfinished widget, and {partials.length} components inherit it
              or something like it.
            </p>
          </Callout>
        </section>

        <section className="mb-10 space-y-4">
          <h2 className="text-xl font-semibold tracking-tight">
            All {COMPONENTS.length}
          </h2>
          <ul className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {COMPONENTS.map((c) => {
              const cases = parityCasesFor(c.slug);
              return (
                <li key={c.slug}>
                  <Link
                    to={`/components/${c.slug}`}
                    className="flex h-full flex-col gap-2 rounded-xl border p-4 transition hover:bg-accent/40"
                  >
                    <div className="flex items-start justify-between gap-2">
                      <span className="font-medium">{c.title}</span>
                      <StatusBadge
                        status={c.status}
                        label={c.status === "built" ? "built" : "partial"}
                      />
                    </div>
                    <p className="text-sm leading-6 text-muted-foreground">
                      {c.blurb}
                    </p>
                    <p className="mt-auto pt-2 font-mono text-[11px] text-muted-foreground/80">
                      {c.odinFile}
                      {cases.length > 0
                        ? ` · ${cases.length} case${cases.length === 1 ? "" : "s"}`
                        : ""}
                    </p>
                  </Link>
                </li>
              );
            })}
          </ul>
        </section>

        <section className="mb-10 space-y-4">
          <h2 className="text-xl font-semibold tracking-tight">
            Why these are partial
          </h2>
          <DataTable
            head={["Component", "Reason"]}
            rows={partials.map((c) => [
              <Link
                to={`/components/${c.slug}`}
                className="font-medium underline underline-offset-4"
              >
                {c.title}
              </Link>,
              c.gap ? GAP_LABEL[c.gap.kind] : "",
            ])}
          />
          <div className="space-y-3">
            {(["overlay", "fixture", "input"] as const).map((k) => (
              <Callout key={k} kind="note" title={GAP_LABEL[k]}>
                <p>
                  <Ticks>{GAP_TEXT[k]}</Ticks>
                </p>
              </Callout>
            ))}
          </div>
        </section>

        <section className="space-y-4">
          <h2 className="text-xl font-semibold tracking-tight">
            Beyond the documented set
          </h2>
          <p className="text-sm leading-7 text-muted-foreground">
            The CLI installs {extras.length} components that are not part of the
            set the official documentation lists. They are here for the same
            reason everything else is — so the gap between what is available and
            what is used is visible rather than guessed at.
          </p>
          <ul className="flex flex-wrap gap-2">
            {extras.map((c) => (
              <li key={c.slug}>
                <Link
                  to={`/components/${c.slug}`}
                  className="inline-flex items-center gap-2 rounded-full border px-3 py-1 text-sm transition hover:bg-accent/50"
                >
                  {c.title}
                </Link>
              </li>
            ))}
          </ul>
        </section>
      </div>
    </Shell>
  );
}
