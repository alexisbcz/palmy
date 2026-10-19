import { useEffect, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Link, NavLink as RRNavLink, useLocation } from "react-router";
import { REPO_URL } from "~/lib/seo";
import { MenuIcon, XIcon } from "lucide-react";

import { cn } from "~/lib/utils";
import { SearchTrigger } from "~/components/search";
import { ThemeToggle } from "~/components/theme-toggle";
import { TOP_NAV, type NavGroup } from "~/lib/nav";
import type { TocEntry } from "~/lib/doc";

/* -------------------------------------------------------------------------- */
/* Header                                                                      */
/* -------------------------------------------------------------------------- */

function Mark() {
  return (
    <Link to="/" className="flex shrink-0 items-center gap-2">
      <span
        aria-hidden="true"
        className="flex size-6 items-center justify-center rounded-md bg-foreground text-[11px] font-bold text-background"
      >
        P
      </span>
      <span className="text-sm font-semibold tracking-tight">Palmframe</span>
    </Link>
  );
}

export function SiteHeader({ sidebar }: { sidebar?: NavGroup[] }) {
  const [navOpen, setNavOpen] = useState(false);
  const location = useLocation();

  // A route change closes the drawer; otherwise tapping a link on a phone
  // navigates behind a sheet that is still covering the page.
  useEffect(() => {
    setNavOpen(false);
  }, [location.pathname]);

  useEffect(() => {
    if (!navOpen) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setNavOpen(false);
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [navOpen]);

  const active = (match: string) =>
    match.split("|").some((m) => location.pathname === m || location.pathname.startsWith(m + "/"));

  return (
    <header className="sticky top-0 z-40 border-b bg-background/80 backdrop-blur">
      <div className="mx-auto flex h-14 max-w-[1600px] items-center gap-3 px-4 lg:px-6">
        <button
          type="button"
          onClick={() => setNavOpen(true)}
          aria-label="Open navigation"
          aria-expanded={navOpen}
          className={cn(
            "-ml-1 inline-flex size-8 items-center justify-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground",
            sidebar ? "lg:hidden" : "md:hidden",
          )}
        >
          <MenuIcon className="size-4" />
        </button>

        <Mark />

        <nav className="ml-4 hidden items-center gap-1 md:flex">
          {TOP_NAV.map((l) => (
            <Link
              key={l.to}
              to={l.to}
              aria-current={active(l.match) ? "page" : undefined}
              className={cn(
                "rounded-md px-2.5 py-1.5 text-sm transition",
                active(l.match)
                  ? "font-medium text-foreground"
                  : "text-muted-foreground hover:text-foreground",
              )}
            >
              {l.label}
            </Link>
          ))}
        </nav>

        <div className="ml-auto flex items-center gap-2">
          <a
            href={REPO_URL}
            target="_blank"
            rel="noreferrer"
            aria-label="Source on GitHub"
            className="hidden size-8 items-center justify-center rounded-md text-muted-foreground transition hover:bg-accent hover:text-foreground sm:inline-flex"
          >
            <GitHubMark className="size-4" />
          </a>
          <SearchTrigger />
          <ThemeToggle />
        </div>
      </div>

      {/* Portalled: the header's backdrop-filter would otherwise become the
          containing block of this fixed layer and clip it to the header. */}
      {navOpen
        ? createPortal(
        <div className="fixed inset-0 z-50 h-dvh">
          <button
            type="button"
            aria-label="Close navigation"
            onClick={() => setNavOpen(false)}
            className="absolute inset-0 bg-black/50"
          />
          <div
            role="dialog"
            aria-modal="true"
            aria-label="Navigation"
            className="thin-scroll absolute inset-y-0 left-0 w-72 max-w-[85vw] overflow-y-auto overscroll-contain border-r bg-background p-4"
          >
            <div className="mb-4 flex items-center justify-between">
              <Mark />
              <button
                type="button"
                onClick={() => setNavOpen(false)}
                aria-label="Close navigation"
                className="inline-flex size-8 items-center justify-center rounded-md text-muted-foreground hover:bg-accent"
              >
                <XIcon className="size-4" />
              </button>
            </div>
            <SidebarNav
              groups={[
                {
                  title: "Sections",
                  links: [
                    ...TOP_NAV.map((l) => ({ to: l.to, label: l.label })),
                    { to: REPO_URL, label: "GitHub" },
                  ],
                },
                ...(sidebar ?? []),
              ]}
            />
          </div>
        </div>,
            document.body,
          )
        : null}
    </header>
  );
}

function GitHubMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true" fill="currentColor" className={className}>
      <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
    </svg>
  );
}

/* -------------------------------------------------------------------------- */
/* Sidebar                                                                     */
/* -------------------------------------------------------------------------- */

function SidebarNav({ groups }: { groups: NavGroup[] }) {
  return (
    <nav className="flex flex-col gap-6 pb-16">
      {groups.map((g) => (
        <div key={g.title}>
          <p className="mb-2 px-2 text-xs font-semibold tracking-wide text-foreground/70 uppercase">
            {g.title}
          </p>
          <ul className="flex flex-col gap-0.5">
            {g.links.map((l) => (
              <li key={l.to}>
                <RRNavLink
                  to={l.to}
                  end
                  className={({ isActive }) =>
                    cn(
                      "flex items-center justify-between gap-2 rounded-md px-2 py-1.5 text-sm transition",
                      isActive
                        ? "bg-accent font-medium text-accent-foreground"
                        : "text-muted-foreground hover:bg-accent/50 hover:text-foreground",
                    )
                  }
                >
                  <span className="truncate">{l.label}</span>
                  {l.planned ? (
                    <span className="shrink-0 rounded border border-amber-600/30 bg-amber-500/10 px-1 py-px text-[10px] font-medium text-amber-700 dark:text-amber-400">
                      plan
                    </span>
                  ) : l.tag ? (
                    <span className="shrink-0 rounded border px-1 py-px text-[10px] text-muted-foreground">
                      {l.tag}
                    </span>
                  ) : null}
                </RRNavLink>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </nav>
  );
}

/* -------------------------------------------------------------------------- */
/* On this page                                                                */
/* -------------------------------------------------------------------------- */

function Toc({ entries }: { entries: TocEntry[] }) {
  const [active, setActive] = useState<string | null>(
    entries.length > 0 ? entries[0].id : null,
  );

  useEffect(() => {
    if (entries.length === 0) return;
    const nodes = entries
      .map((e) => document.getElementById(e.id))
      .filter((n): n is HTMLElement => Boolean(n));
    if (nodes.length === 0) return;

    const obs = new IntersectionObserver(
      (records) => {
        const visible = records
          .filter((r) => r.isIntersecting)
          .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
        if (visible.length > 0) setActive(visible[0].target.id);
      },
      { rootMargin: "-80px 0px -70% 0px", threshold: [0, 1] },
    );
    for (const n of nodes) obs.observe(n);
    return () => obs.disconnect();
  }, [entries]);

  if (entries.length === 0) return null;

  return (
    <div className="thin-scroll sticky top-14 max-h-[calc(100vh-3.5rem)] overflow-y-auto py-8 pr-4">
      <p className="mb-3 text-xs font-semibold tracking-wide text-foreground/70 uppercase">
        On this page
      </p>
      <ul className="flex flex-col gap-1 border-l">
        {entries.map((e) => (
          <li key={e.id}>
            <a
              href={`#${e.id}`}
              className={cn(
                "-ml-px block border-l py-1 text-sm transition",
                e.depth === 3 ? "pl-6" : "pl-3",
                active === e.id
                  ? "border-foreground font-medium text-foreground"
                  : "border-transparent text-muted-foreground hover:text-foreground",
              )}
            >
              {e.title}
            </a>
          </li>
        ))}
      </ul>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Shell                                                                       */
/* -------------------------------------------------------------------------- */

export function Shell({
  sidebar,
  toc,
  children,
  wide = false,
}: {
  sidebar?: NavGroup[];
  toc?: TocEntry[];
  children: ReactNode;
  /** Drops the right rail and lets the content use the full column. */
  wide?: boolean;
}) {
  const hasToc = Boolean(toc && toc.length > 0) && !wide;

  return (
    <div className="min-h-screen">
      <SiteHeader sidebar={sidebar} />

      <div
        className={cn(
          "mx-auto max-w-[1600px] px-4 lg:px-6",
          (sidebar || hasToc) && "lg:grid lg:gap-8",
          sidebar && hasToc
            ? "lg:grid-cols-[16rem_minmax(0,1fr)] xl:grid-cols-[16rem_minmax(0,1fr)_14rem]"
            : sidebar
              ? "lg:grid-cols-[16rem_minmax(0,1fr)]"
              : hasToc
                ? "lg:grid-cols-[minmax(0,1fr)] xl:grid-cols-[minmax(0,1fr)_14rem]"
                : undefined,
        )}
      >
        {sidebar ? (
          <>
            {/* Desktop rail */}
            <aside className="thin-scroll hidden lg:sticky lg:top-14 lg:block lg:max-h-[calc(100vh-3.5rem)] lg:overflow-y-auto lg:py-8">
              <SidebarNav groups={sidebar} />
            </aside>

          </>
        ) : null}

        <main className="min-w-0 py-8">{children}</main>

        {hasToc ? (
          <aside className="hidden xl:block">
            <Toc entries={toc!} />
          </aside>
        ) : null}
      </div>

      <SiteFooter />
    </div>
  );
}

export function SiteFooter() {
  return (
    <footer className="mt-8 border-t">
      <div className="mx-auto flex max-w-[1600px] flex-col gap-2 px-4 py-8 text-xs text-muted-foreground lg:flex-row lg:items-center lg:justify-between lg:px-6">
        <p>
          Palmframe and palmy. The toolkit is built and measured; the
          distribution boots in QEMU and has never run on real hardware; the
          vision pages are a plan, and say so.
        </p>
        <p className="flex flex-wrap gap-4">
          <Link to="/distro/missing" className="hover:text-foreground">
            What the distribution lacks
          </Link>
          <Link to="/docs/limitations" className="hover:text-foreground">
            What the toolkit lacks
          </Link>
          <Link to="/docs/parity" className="hover:text-foreground">
            Parity report
          </Link>
          <Link to="/distro/contributing" className="hover:text-foreground">
            Contributing
          </Link>
          <a href={REPO_URL} className="hover:text-foreground">
            GitHub
          </a>
        </p>
      </div>
    </footer>
  );
}
