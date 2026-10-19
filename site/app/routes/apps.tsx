import { Link } from "react-router";
import { seo } from "~/lib/seo";
import { Shell } from "~/components/shell";
import { Callout, StatusBadge, Ticks } from "~/components/bits";
import { Shot } from "~/components/shot";
import { APPS, CATEGORIES, appsByCategory } from "~/content/apps";
import type { TocEntry } from "~/lib/doc";

export function meta() {
  return seo({
    title: "Applications",
    description: `${APPS.length} applications built on palmy: a window manager, a login greeter, a file browser, a mail stack, an office suite, media players and more.`,
    path: "/apps",
  });
}

function slugifyCategory(c: string) {
  return c.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

export default function AppsPage() {
  const groups = appsByCategory();
  const toc: TocEntry[] = [
    { id: "about", title: "About these", depth: 2 },
    ...groups.map((g) => ({
      id: slugifyCategory(g.category),
      title: g.category,
      depth: 2 as const,
    })),
  ];

  return (
    <Shell toc={toc}>
      <div className="mx-auto max-w-5xl">
        <header className="mb-8 space-y-3">
          <p className="text-xs text-muted-foreground">Palmy</p>
          <h1 className="text-3xl font-bold tracking-tight sm:text-4xl">
            {APPS.length} applications
          </h1>
          <p className="max-w-2xl text-base leading-7 text-muted-foreground">
            Everything here is built on{" "}
            <Link to="/docs/introduction" className="underline underline-offset-4">
              palmy
            </Link>
            , which means a software rasterizer, a hand-rolled display protocol
            and a three-line dependency list. They are the reason the toolkit
            exists: a toolkit nobody has written forty applications against has
            not been tested.
          </p>
        </header>

        <div className="prose-doc max-w-none">
          <section>
            <h2 id="about">About these</h2>
            <div className="not-prose grid gap-3 sm:grid-cols-3">
              <div className="rounded-xl border p-4">
                <p className="font-mono text-2xl font-semibold">
                  {APPS.length}
                </p>
                <p className="mt-1 text-xs text-muted-foreground">
                  applications
                </p>
              </div>
              <div className="rounded-xl border p-4">
                <p className="font-mono text-2xl font-semibold">
                  {APPS.filter((a) => a.demo).length}
                </p>
                <p className="mt-1 text-xs text-muted-foreground">
                  with a scripted demo recording
                </p>
              </div>
              <div className="rounded-xl border p-4">
                <p className="font-mono text-2xl font-semibold">
                  {CATEGORIES.length}
                </p>
                <p className="mt-1 text-xs text-muted-foreground">categories</p>
              </div>
            </div>
            <Callout kind="note" title="Recorded, not mocked">
              <p>
                Each demo is a plain-text script handed to a recorder that
                starts its own compositor with its own socket, its own virtual
                output and its own seat, so a recording never appears on
                anyone&rsquo;s screen and keystrokes cannot land in another
                window. Two applications have no recording: the mail engine,
                which is headless by construction, and the reader, which keeps
                reference renders instead.
              </p>
              <p>
                The screenshots below are produced the same way — rasterized by
                palmy. Where one has not been generated, the card shows a
                labelled placeholder rather than a broken image.
              </p>
            </Callout>
          </section>

          {groups.map((g) => (
            <section key={g.category}>
              <h2 id={slugifyCategory(g.category)}>{g.category}</h2>
              <ul className="not-prose grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
                {g.apps.map((a) => (
                  <li
                    key={a.slug}
                    id={a.slug}
                    className="flex scroll-mt-24 flex-col overflow-hidden rounded-xl border"
                  >
                    <Shot
                      names={[`app-${a.slug}`, `apps-${a.slug}`, a.slug]}
                      alt={`${a.name}, rendered by palmy`}
                      aspect="16 / 10"
                      className="rounded-none border-0 border-b"
                    />
                    <div className="flex flex-1 flex-col gap-2 p-4">
                      <div className="flex items-center justify-between gap-2">
                        <code className="text-sm font-semibold">{a.name}</code>
                        {a.headless ? (
                          <StatusBadge status="built" label="headless" />
                        ) : null}
                      </div>
                      <p className="text-sm leading-6 text-muted-foreground">
                        {a.summary}
                      </p>
                      {a.note ? (
                        <p className="mt-auto border-t pt-2 text-xs leading-5 text-muted-foreground/90">
                          <Ticks>{a.note}</Ticks>
                        </p>
                      ) : null}
                    </div>
                  </li>
                ))}
              </ul>
            </section>
          ))}
        </div>
      </div>
    </Shell>
  );
}
