import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router";
import { FileTextIcon, HashIcon, SearchIcon } from "lucide-react";

import {
  Command,
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "~/components/ui/command";
import { Kbd } from "~/components/bits";
import { PALMY_DOCS } from "~/content/docs-palmy";
import { VISION_DOCS } from "~/content/docs-vision";
import { COMPONENTS } from "~/content/components";
import { APPS } from "~/content/apps";
import { GENERATED } from "~/lib/generated-nav";

/**
 * One searchable unit: a page's opening text, or one of its sections. Built
 * at build time from the prerendered HTML of every page (scripts/postbuild.mjs)
 * and fetched the first time the palette opens, so the text of the whole site
 * is searchable without shipping it in the bundle.
 */
type Rec = {
  /** URL, with #fragment for a section. */
  u: string;
  /** Page title. */
  t: string;
  /** Section heading, empty for the page's lead. */
  s: string;
  /** Section text. */
  x: string;
  /** Site section: Distribution, palmy, Components... */
  g: string;
};

/** Titles and descriptions only: what is searchable before the index loads. */
function titleIndex(): Rec[] {
  const gen = (c: "distro" | "reference", g: string) =>
    GENERATED[c].groups.flatMap((grp) =>
      grp.pages.map((p) => ({ u: p.url, t: p.title, s: "", x: p.description, g })),
    );
  return [
    ...gen("distro", "Distribution"),
    ...PALMY_DOCS.map((d) => ({ u: `/docs/${d.slug}`, t: d.title, s: "", x: d.description, g: "palmy" })),
    ...gen("reference", "palmy"),
    ...COMPONENTS.map((c) => ({ u: `/components/${c.slug}`, t: c.title, s: "", x: c.blurb, g: "Components" })),
    ...APPS.map((a) => ({ u: `/apps#${a.slug}`, t: a.name, s: "", x: a.summary, g: "Applications" })),
    ...VISION_DOCS.map((d) => ({
      u: `/vision/${d.slug}`,
      t: d.slug === "overview" ? "Palmy, the vision" : d.title,
      s: "",
      x: d.description,
      g: "Vision",
    })),
  ];
}

const norm = (s: string) => s.toLowerCase();

type Hit = { rec: Rec; score: number; at: number };

/**
 * Every word of the query must appear somewhere in the record. A word in the
 * page title counts most, then the section heading, then the body; a phrase
 * match and a title that starts with the query win ties.
 */
function search(index: Rec[], query: string): Hit[] {
  const q = norm(query.trim());
  if (!q) return [];
  const words = q.split(/\s+/).filter(Boolean);
  const hits: Hit[] = [];
  for (const rec of index) {
    const t = norm(rec.t);
    const s = norm(rec.s);
    const x = norm(rec.x);
    let score = 0;
    let ok = true;
    for (const w of words) {
      const inT = t.includes(w);
      const inS = s.includes(w);
      const inX = x.includes(w);
      if (!inT && !inS && !inX) {
        ok = false;
        break;
      }
      score += (inT ? 6 : 0) + (inS ? 4 : 0) + (inX ? 1 : 0);
    }
    if (!ok) continue;
    if (t.startsWith(q)) score += 8;
    if (s.startsWith(q)) score += 5;
    if (!rec.s) score += 1; // prefer the page over its first section on ties
    const at = x.indexOf(q) >= 0 ? x.indexOf(q) : x.indexOf(words[0]);
    if (x.includes(q)) score += 2;
    hits.push({ rec, score, at });
  }
  hits.sort((a, b) => b.score - a.score || a.rec.u.length - b.rec.u.length);
  return hits.slice(0, 40);
}

/** About 140 characters of body text around the match, with the match marked. */
function Snippet({ text, query, at }: { text: string; query: string; at: number }) {
  if (!text) return null;
  const start = Math.max(0, at - 50);
  const slice = (start > 0 ? "…" : "") + text.slice(start, start + 150) + (start + 150 < text.length ? "…" : "");
  const words = query
    .trim()
    .split(/\s+/)
    .filter((w) => w.length > 1)
    .map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  if (!words.length) return <>{slice}</>;
  const parts = slice.split(new RegExp(`(${words.join("|")})`, "gi"));
  return (
    <>
      {parts.map((p, i) =>
        i % 2 === 1 ? (
          <mark key={i} className="rounded-sm bg-amber-500/25 px-px text-foreground">
            {p}
          </mark>
        ) : (
          <span key={i}>{p}</span>
        ),
      )}
    </>
  );
}

const GROUP_ORDER = ["Distribution", "palmy", "Components", "Applications", "Vision"];

export function SearchTrigger() {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [full, setFull] = useState<Rec[] | null>(null);
  const loading = useRef(false);
  const navigate = useNavigate();
  const titles = useMemo(titleIndex, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "k" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        setOpen((v) => !v);
      }
      if (e.key === "/" && !open) {
        const t = e.target as HTMLElement | null;
        const typing = t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable);
        if (!typing) {
          e.preventDefault();
          setOpen(true);
        }
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open]);

  // The full-text index is fetched once, the first time the palette opens.
  useEffect(() => {
    if (!open || full || loading.current) return;
    loading.current = true;
    fetch("/search-index.json")
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
      .then((data: Rec[]) => setFull(data))
      .catch(() => {
        // In development the index does not exist; titles still work.
        loading.current = false;
      });
  }, [open, full]);

  const index = full ?? titles;
  const hits = useMemo(() => search(index, query), [index, query]);

  const browse = useMemo(
    () =>
      GROUP_ORDER.map((g) => ({
        name: g,
        recs: titles.filter((r) => r.g === g),
      })),
    [titles],
  );

  const go = (to: string) => {
    setOpen(false);
    setQuery("");
    navigate(to);
  };

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        aria-label="Search documentation"
        className="inline-flex h-8 items-center gap-2 rounded-md border bg-muted/40 px-2.5 text-xs text-muted-foreground transition hover:bg-accent hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none sm:w-56 sm:justify-between"
      >
        <span className="flex items-center gap-2">
          <SearchIcon className="size-3.5" />
          <span className="hidden sm:inline">Search documentation…</span>
        </span>
        <span className="hidden sm:inline">
          <Kbd>⌘K</Kbd>
        </span>
      </button>

      <CommandDialog
        open={open}
        onOpenChange={(v) => {
          setOpen(v);
          if (!v) setQuery("");
        }}
        title="Search"
        description="Search the text of every page: the distribution, the toolkit, the components and the applications."
        className="sm:max-w-2xl"
      >
        <Command shouldFilter={false}>
          <CommandInput
            placeholder={full ? "Search every page…" : "Search page titles…"}
            value={query}
            onValueChange={setQuery}
          />
          <CommandList className="max-h-[min(70vh,28rem)]">
            <CommandEmpty>Nothing matched.</CommandEmpty>
            {query.trim()
              ? hits.length > 0 && (
                  <CommandGroup heading={`${hits.length === 40 ? "Top 40" : hits.length} result${hits.length === 1 ? "" : "s"}`}>
                    {hits.map(({ rec, at }) => (
                      <CommandItem
                        key={rec.u + rec.s}
                        value={rec.u + "\u0000" + rec.s}
                        onSelect={() => go(rec.u)}
                        className="flex flex-col items-start gap-0.5 py-2"
                      >
                        <span className="flex w-full min-w-0 items-center gap-1.5">
                          {rec.s ? (
                            <HashIcon className="size-3.5 shrink-0 text-muted-foreground" />
                          ) : (
                            <FileTextIcon className="size-3.5 shrink-0 text-muted-foreground" />
                          )}
                          <span className="truncate font-medium">{rec.s || rec.t}</span>
                          <span className="ml-auto shrink-0 pl-2 text-[11px] text-muted-foreground">
                            {rec.s ? `${rec.t} · ` : ""}
                            {rec.g}
                          </span>
                        </span>
                        <span className="line-clamp-2 pl-5 text-xs leading-5 text-muted-foreground">
                          <Snippet text={rec.x} query={query} at={at} />
                        </span>
                      </CommandItem>
                    ))}
                  </CommandGroup>
                )
              : browse.map((g) =>
                  g.recs.length === 0 ? null : (
                    <CommandGroup key={g.name} heading={g.name}>
                      {g.recs.map((r) => (
                        <CommandItem key={r.u} value={r.u} onSelect={() => go(r.u)}>
                          <span className="font-medium">{r.t}</span>
                          <span className="ml-2 truncate text-xs text-muted-foreground">{r.x}</span>
                        </CommandItem>
                      ))}
                    </CommandGroup>
                  ),
                )}
          </CommandList>
        </Command>
      </CommandDialog>
    </>
  );
}
