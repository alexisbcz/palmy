import { Link } from "react-router";
import { ArrowLeftIcon, ArrowRightIcon, PencilIcon, FileCodeIcon } from "lucide-react";

import { Markdown, type Compact } from "~/components/markdown";
import type { GenNavPage } from "~/lib/generated-nav";

export type GeneratedPageData = {
  title: string;
  description: string;
  group: string;
  toc: { id: string; title: string; depth: 2 | 3 }[];
  source: {
    path: string;
    edit: string;
    view: string;
    generated: { path: string; url: string }[];
  };
  updated: string | null;
  /** A Compact tree; typed loosely so route type inference stays shallow. */
  hast: unknown;
};

function formatDate(d: string) {
  const [y, m, day] = d.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, day)).toLocaleDateString("en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric",
    timeZone: "UTC",
  });
}

export function GeneratedArticle({
  page,
  eyebrow,
  prev,
  next,
}: {
  page: GeneratedPageData;
  eyebrow: string;
  prev?: GenNavPage;
  next?: GenNavPage;
}) {
  const synced = !page.source.path.startsWith("site/");
  return (
    <article className="mx-auto max-w-3xl">
      <div className="mb-8 space-y-3">
        <p className="text-xs text-muted-foreground">
          {eyebrow} <span aria-hidden="true">/</span> {page.group}
        </p>
        <h1 className="text-3xl font-bold tracking-tight sm:text-4xl">{page.title}</h1>
        <p className="text-base leading-7 text-muted-foreground">{page.description}</p>
      </div>

      <Markdown tree={page.hast as Compact} />

      <footer className="mt-14 flex flex-col gap-3 border-t pt-5 text-xs text-muted-foreground sm:flex-row sm:items-start sm:justify-between">
        <div className="space-y-1.5">
          {synced ? (
            <p>
              This page is <code className="font-mono">{page.source.path}</code> from the
              repository, published as written.
            </p>
          ) : null}
          {page.source.generated.length ? (
            <p className="flex flex-wrap items-center gap-x-1.5 gap-y-1">
              <FileCodeIcon className="size-3.5" aria-hidden="true" />
              Tables generated from
              {page.source.generated.map((g, i) => (
                <span key={g.path}>
                  <a
                    href={g.url}
                    target="_blank"
                    rel="noreferrer"
                    className="font-mono underline underline-offset-4 hover:text-foreground"
                  >
                    {g.path}
                  </a>
                  {i < page.source.generated.length - 1 ? "," : ""}
                </span>
              ))}
            </p>
          ) : null}
          {page.updated ? <p>Source last changed {formatDate(page.updated)}.</p> : null}
        </div>
        <a
          href={page.source.edit}
          target="_blank"
          rel="noreferrer"
          className="inline-flex shrink-0 items-center gap-1.5 rounded-md border px-2.5 py-1.5 font-medium text-foreground transition hover:bg-accent"
        >
          <PencilIcon className="size-3.5" aria-hidden="true" />
          Edit on GitHub
        </a>
      </footer>

      {prev || next ? (
        <nav className="mt-8 flex items-stretch gap-3">
          {prev ? (
            <Link
              to={prev.url}
              className="flex flex-1 flex-col gap-1 rounded-xl border p-4 transition hover:bg-accent/40"
            >
              <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
                <ArrowLeftIcon className="size-3" />
                Previous
              </span>
              <span className="text-sm font-medium">{prev.nav}</span>
            </Link>
          ) : (
            <div className="flex-1" />
          )}
          {next ? (
            <Link
              to={next.url}
              className="flex flex-1 flex-col items-end gap-1 rounded-xl border p-4 text-right transition hover:bg-accent/40"
            >
              <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
                Next
                <ArrowRightIcon className="size-3" />
              </span>
              <span className="text-sm font-medium">{next.nav}</span>
            </Link>
          ) : (
            <div className="flex-1" />
          )}
        </nav>
      ) : null}
    </article>
  );
}
