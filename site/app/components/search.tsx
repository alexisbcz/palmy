import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router";
import { SearchIcon } from "lucide-react";

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
import { PALMFRAME_DOCS } from "~/content/docs-palmframe";
import { COMPONENTS } from "~/content/components";
import { APPS } from "~/content/apps";

type Hit = { group: string; label: string; hint: string; to: string };

/**
 * The default fuzzy filter scores a subsequence anywhere in the string, so
 * "dropdown" matched half the documentation through its descriptions. For a
 * docs palette the title is what people are typing, so it is ranked first and
 * the description is only a fallback.
 */
function score(value: string, search: string, keywords?: string[]): number {
  const q = search.trim().toLowerCase();
  if (!q) return 1;
  const v = value.toLowerCase();
  if (v.startsWith(q)) return 1;
  if (v.includes(q)) return 0.8;
  const k = (keywords ?? []).join(" ").toLowerCase();
  if (k.includes(q)) return 0.4;
  const words = q.split(/\s+/).filter(Boolean);
  if (words.length > 1 && words.every((w) => v.includes(w) || k.includes(w))) {
    return 0.2;
  }
  return 0;
}

function buildIndex(): Hit[] {
  return [
    ...PALMY_DOCS.map((d) => ({
      group: "palmy",
      label: d.title,
      hint: d.description,
      to: `/docs/${d.slug}`,
    })),
    ...PALMFRAME_DOCS.map((d) => ({
      group: "Palmframe",
      label: d.slug === "overview" ? "Overview" : d.title,
      hint: d.description,
      to: `/palmframe/${d.slug}`,
    })),
    ...COMPONENTS.map((c) => ({
      group: "Components",
      label: c.title,
      hint: c.blurb,
      to: `/components/${c.slug}`,
    })),
    ...APPS.map((a) => ({
      group: "Applications",
      label: a.name,
      hint: a.summary,
      to: `/apps#${a.slug}`,
    })),
  ];
}

export function SearchTrigger() {
  const [open, setOpen] = useState(false);
  const navigate = useNavigate();
  const index = useMemo(buildIndex, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "k" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        setOpen((v) => !v);
      }
      if (e.key === "/" && !open) {
        const t = e.target as HTMLElement | null;
        const typing =
          t &&
          (t.tagName === "INPUT" ||
            t.tagName === "TEXTAREA" ||
            t.isContentEditable);
        if (!typing) {
          e.preventDefault();
          setOpen(true);
        }
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open]);

  const groups = useMemo(() => {
    const order = ["palmy", "Palmframe", "Components", "Applications"];
    return order.map((g) => ({
      name: g,
      hits: index.filter((h) => h.group === g),
    }));
  }, [index]);

  const go = (to: string) => {
    setOpen(false);
    navigate(to);
  };

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
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
        onOpenChange={setOpen}
        title="Search"
        description="Search the documentation, the components and the applications."
      >
        <Command filter={score}>
          <CommandInput placeholder="Search documentation…" />
          <CommandList className="max-h-80">
            <CommandEmpty>Nothing matched.</CommandEmpty>
          {groups.map((g) =>
            g.hits.length === 0 ? null : (
              <CommandGroup key={g.name} heading={g.name}>
                {g.hits.map((h) => (
                  <CommandItem
                    key={h.to + h.label}
                    value={h.label}
                    keywords={[h.hint, h.to]}
                    onSelect={() => go(h.to)}
                  >
                    <span className="font-medium">{h.label}</span>
                    <span className="ml-2 truncate text-xs text-muted-foreground">
                      {h.hint}
                    </span>
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
