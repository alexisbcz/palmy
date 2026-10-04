import { useEffect, useState, type ReactNode } from "react";
import { Link, NavLink as RRNavLink, useLocation } from "react-router";
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

export function SiteHeader({
  onOpenNav,
  hasNav,
}: {
  onOpenNav?: () => void;
  hasNav?: boolean;
}) {
  return (
    <header className="sticky top-0 z-40 border-b bg-background/80 backdrop-blur">
      <div className="mx-auto flex h-14 max-w-[1600px] items-center gap-3 px-4 lg:px-6">
        {hasNav ? (
          <button
            type="button"
            onClick={onOpenNav}
            aria-label="Open navigation"
            className="-ml-1 inline-flex size-8 items-center justify-center rounded-md text-muted-foreground hover:bg-accent hover:text-foreground lg:hidden"
          >
            <MenuIcon className="size-4" />
          </button>
        ) : null}

        <Mark />

        <nav className="ml-4 hidden items-center gap-1 md:flex">
          {TOP_NAV.map((l) => (
            <RRNavLink
              key={l.to}
              to={l.to}
              className={({ isActive }) =>
                cn(
                  "rounded-md px-2.5 py-1.5 text-sm transition",
                  isActive
                    ? "font-medium text-foreground"
                    : "text-muted-foreground hover:text-foreground",
                )
              }
            >
              {l.label}
            </RRNavLink>
          ))}
        </nav>

        <div className="ml-auto flex items-center gap-2">
          <SearchTrigger />
          <ThemeToggle />
        </div>
      </div>
    </header>
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
  const [navOpen, setNavOpen] = useState(false);
  const location = useLocation();

  // A route change closes the drawer; otherwise tapping a link on a phone
  // navigates behind a sheet that is still covering the page.
  useEffect(() => {
    setNavOpen(false);
  }, [location.pathname]);

  const hasToc = Boolean(toc && toc.length > 0) && !wide;

  return (
    <div className="min-h-screen">
      <SiteHeader hasNav={Boolean(sidebar)} onOpenNav={() => setNavOpen(true)} />

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

            {/* Phone drawer */}
            {navOpen ? (
              <div className="fixed inset-0 z-50 lg:hidden">
                <button
                  type="button"
                  aria-label="Close navigation"
                  onClick={() => setNavOpen(false)}
                  className="absolute inset-0 bg-black/50"
                />
                <div className="thin-scroll absolute inset-y-0 left-0 w-72 max-w-[85vw] overflow-y-auto border-r bg-background p-4">
                  <div className="mb-4 flex items-center justify-between">
                    <span className="text-sm font-semibold">Navigation</span>
                    <button
                      type="button"
                      onClick={() => setNavOpen(false)}
                      aria-label="Close navigation"
                      className="inline-flex size-8 items-center justify-center rounded-md text-muted-foreground hover:bg-accent"
                    >
                      <XIcon className="size-4" />
                    </button>
                  </div>
                  <SidebarNav groups={sidebar} />
                </div>
              </div>
            ) : null}
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
          distribution is a plan, and every page marks which it is.
        </p>
        <p className="flex flex-wrap gap-4">
          <Link to="/docs/limitations" className="hover:text-foreground">
            What is not here
          </Link>
          <Link to="/docs/parity" className="hover:text-foreground">
            Parity report
          </Link>
          <Link to="/palmframe/hard-parts" className="hover:text-foreground">
            The hard parts
          </Link>
        </p>
      </div>
    </footer>
  );
}
