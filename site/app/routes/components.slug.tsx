import { Link } from "react-router";
import { seo } from "~/lib/seo";
import type { Route } from "./+types/components.slug";
import { Shell } from "~/components/shell";
import { Callout, DataTable, StatusBadge, Ticks } from "~/components/bits";
import { ComponentPreview } from "~/components/component-preview";
import { Shot } from "~/components/shot";
import { componentsSidebar } from "~/lib/nav";
import {
  COMPONENTS,
  GAP_TEXT,
  componentBySlug,
  parityCasesFor,
} from "~/content/components";
import type { TocEntry } from "~/lib/doc";

export function meta({ loaderData: data, location }: Route.MetaArgs) {
  if (!data) return [{ title: "Not found — Components" }];
  return seo({
    title: `${data.title} — palmy components`,
    fullTitle: true,
    description: data.blurb,
    path: location.pathname,
  });
}

export function loader({ params }: Route.LoaderArgs) {
  const c = componentBySlug(params.slug ?? "");
  if (!c) throw new Response("Not found", { status: 404 });
  return { slug: c.slug, title: c.title, blurb: c.blurb };
}

export default function ComponentPage({ loaderData }: Route.ComponentProps) {
  const c = componentBySlug(loaderData.slug)!;
  const i = COMPONENTS.findIndex((x) => x.slug === c.slug);
  const prev = COMPONENTS[i - 1];
  const next = COMPONENTS[i + 1];
  const cases = parityCasesFor(c.slug);

  const toc: TocEntry[] = [
    { id: "example", title: "Example", depth: 2 },
    { id: "in-palmy", title: "In palmy", depth: 2 },
    ...(cases.length > 0
      ? [{ id: "measured", title: "Measured", depth: 2 as const }]
      : []),
    { id: "rendered-by-palmy", title: "Rendered by palmy", depth: 2 },
  ];

  return (
    <Shell sidebar={componentsSidebar()} toc={toc}>
      <article className="mx-auto max-w-3xl">
        <header className="mb-8 space-y-3">
          <p className="text-xs text-muted-foreground">Components</p>
          <div className="flex flex-wrap items-center gap-3">
            <h1 className="text-3xl font-bold tracking-tight sm:text-4xl">
              {c.title}
            </h1>
            <StatusBadge status={c.status} />
            {c.extra ? (
              <span className="rounded-full border px-2 py-0.5 text-[11px] text-muted-foreground">
                beyond the documented set
              </span>
            ) : null}
          </div>
          <p className="text-base leading-7 text-muted-foreground">{c.blurb}</p>
        </header>

        <div className="prose-doc">
          <section>
            <h2 id="example">Example</h2>
            <ComponentPreview slug={c.slug} odin={c.odin} react={c.react} />
          </section>

          <section>
            <h2 id="in-palmy">In palmy</h2>

            {c.status === "built" ? (
              <Callout kind="tip" title="palmy implements this">
                <p>
                  The Odin widget lives in <code>{c.odinFile}</code>. It takes
                  the state it should be in and draws it; drive{" "}
                  <code>State&#123;hover, focus, disabled, invalid&#125;</code>{" "}
                  from palmy&rsquo;s <code>is_hovered</code> and{" "}
                  <code>focused</code> for live interaction.
                </p>
              </Callout>
            ) : c.status === "partial" ? (
              <Callout
                kind="warn"
                title="palmy implements this, with one piece left to the application"
              >
                <p>{c.gap ? <Ticks>{c.gap.detail}</Ticks> : null}</p>
                <p>
                  {c.gap ? <Ticks>{GAP_TEXT[c.gap.kind]}</Ticks> : null}
                </p>
              </Callout>
            ) : (
              <Callout kind="planned" title="palmy does not implement this">
                <p>
                  There is no Odin widget for {c.title}. It is listed here
                  anyway, because a documentation site that silently omits what
                  is missing is the more misleading of the two options.
                </p>
              </Callout>
            )}

            <DataTable
              head={["", ""]}
              rows={[
                ["Odin source", <code>{c.odinFile}</code>],
                [
                  "React source",
                  <code>app/components/ui/{c.slug}.tsx</code>,
                ],
                [
                  "Shares its Odin file with",
                  c.sharedWith && c.sharedWith.length > 0 ? (
                    <span className="flex flex-wrap gap-2">
                      {c.sharedWith.map((s) => (
                        <Link
                          key={s}
                          to={`/components/${s}`}
                          className="underline underline-offset-4"
                        >
                          {s}
                        </Link>
                      ))}
                    </span>
                  ) : (
                    <span className="text-muted-foreground">nothing</span>
                  ),
                ],
                [
                  "Measured cases",
                  cases.length > 0 ? (
                    String(cases.length)
                  ) : (
                    <span className="text-muted-foreground">
                      none under this name in the report
                    </span>
                  ),
                ],
              ]}
            />
          </section>

          {cases.length > 0 ? (
            <section>
              <h2 id="measured">Measured</h2>
              <p>
                Each row is one case rendered twice — once by Chromium from the
                React source, once by palmy — and diffed. The error is glyph
                antialiasing;{" "}
                <Link to="/docs/parity">zero is not reachable</Link> against a
                hinted FreeType rasterizer, and geometry is where exactness is
                visible.
              </p>
              <DataTable
                head={["Case", "Size", "Mean error", "Within 2/255"]}
                rows={cases.map((x) => [
                  <code>{x.id}</code>,
                  <span className="font-mono text-xs">{x.size}</span>,
                  <span className="font-mono text-xs">{x.mae.toFixed(3)}</span>,
                  <span className="font-mono text-xs">
                    {x.within2.toFixed(2)}%
                  </span>,
                ])}
              />
            </section>
          ) : null}

          <section>
            <h2 id="rendered-by-palmy">Rendered by palmy</h2>
            <p>
              Rasterized by the Odin renderer with no browser involved. If the
              frame below is a placeholder, that capture has not been generated.
            </p>
            <div className="not-prose">
              <Shot
                names={[
                  `component-${c.slug}`,
                  `components-${c.slug}`,
                  c.slug,
                  ...cases.slice(0, 1).map((x) => x.id),
                ]}
                alt={`${c.title}, rendered by palmy`}
                aspect="16 / 9"
              />
            </div>
          </section>
        </div>

        <nav className="mt-16 flex items-stretch gap-3 border-t pt-6">
          {prev ? (
            <Link
              to={`/components/${prev.slug}`}
              className="flex flex-1 flex-col gap-1 rounded-xl border p-4 transition hover:bg-accent/40"
            >
              <span className="text-xs text-muted-foreground">Previous</span>
              <span className="text-sm font-medium">{prev.title}</span>
            </Link>
          ) : (
            <div className="flex-1" />
          )}
          {next ? (
            <Link
              to={`/components/${next.slug}`}
              className="flex flex-1 flex-col items-end gap-1 rounded-xl border p-4 text-right transition hover:bg-accent/40"
            >
              <span className="text-xs text-muted-foreground">Next</span>
              <span className="text-sm font-medium">{next.title}</span>
            </Link>
          ) : (
            <div className="flex-1" />
          )}
        </nav>
      </article>
    </Shell>
  );
}
