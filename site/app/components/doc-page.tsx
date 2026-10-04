import { Link } from "react-router";
import { ArrowLeftIcon, ArrowRightIcon, LinkIcon } from "lucide-react";
import type { DocPage } from "~/lib/doc";
import { StatusBadge } from "~/components/bits";

function Anchor({ id }: { id: string }) {
  return (
    <a
      href={`#${id}`}
      aria-label="Link to this section"
      className="ml-2 inline-flex align-middle text-muted-foreground opacity-0 transition group-hover:opacity-100 focus-visible:opacity-100"
    >
      <LinkIcon className="size-3.5" />
    </a>
  );
}

export function DocArticle({
  page,
  base,
  prev,
  next,
  eyebrow,
}: {
  page: DocPage;
  base: string;
  prev?: { to: string; label: string };
  next?: { to: string; label: string };
  eyebrow: string;
}) {
  return (
    <article className="mx-auto max-w-3xl">
      <div className="mb-8 space-y-3">
        <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
          <span>{eyebrow}</span>
          {page.planned ? (
            <StatusBadge status="planned" label="Planned, not built" />
          ) : null}
        </div>
        <h1 className="text-3xl font-bold tracking-tight sm:text-4xl">
          {page.title}
        </h1>
        <p className="text-base leading-7 text-muted-foreground">
          {page.description}
        </p>
      </div>

      <div className="prose-doc">
        {page.lead ? page.lead() : null}

        {page.sections.map((s) => (
          <section key={s.id} className="scroll-mt-24">
            <h2 id={s.id} className="group">
              {s.title}
              <Anchor id={s.id} />
            </h2>
            {s.body()}
            {(s.children ?? []).map((c) => (
              <div key={c.id}>
                <h3 id={c.id} className="group">
                  {c.title}
                  <Anchor id={c.id} />
                </h3>
                {c.body()}
              </div>
            ))}
          </section>
        ))}
      </div>

      {prev || next ? (
        <nav className="mt-16 flex items-stretch gap-3 border-t pt-6">
          {prev ? (
            <Link
              to={prev.to}
              className="group flex flex-1 flex-col gap-1 rounded-xl border p-4 transition hover:bg-accent/40"
            >
              <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
                <ArrowLeftIcon className="size-3" />
                Previous
              </span>
              <span className="text-sm font-medium">{prev.label}</span>
            </Link>
          ) : (
            <div className="flex-1" />
          )}
          {next ? (
            <Link
              to={next.to}
              className="group flex flex-1 flex-col items-end gap-1 rounded-xl border p-4 text-right transition hover:bg-accent/40"
            >
              <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
                Next
                <ArrowRightIcon className="size-3" />
              </span>
              <span className="text-sm font-medium">{next.label}</span>
            </Link>
          ) : (
            <div className="flex-1" />
          )}
        </nav>
      ) : null}

      <p className="mt-8 text-xs text-muted-foreground">
        Section of{" "}
        <Link to={base} className="underline underline-offset-4">
          {eyebrow}
        </Link>
        .
      </p>
    </article>
  );
}
