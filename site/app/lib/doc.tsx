import type { ReactNode } from "react";

/**
 * A documentation page is data, not markup, so the "On this page" rail and the
 * headings in the body are generated from one list and cannot drift apart.
 */
export type DocSection = {
  id: string;
  title: string;
  body: () => ReactNode;
  children?: { id: string; title: string; body: () => ReactNode }[];
};

export type DocPage = {
  slug: string;
  title: string;
  description: string;
  /** Rendered above the first heading, with no heading of its own. */
  lead?: () => ReactNode;
  sections: DocSection[];
  /** Marks a page that documents something planned rather than built. */
  planned?: boolean;
};

export type TocEntry = { id: string; title: string; depth: 2 | 3 };

export function tocOf(page: DocPage): TocEntry[] {
  const out: TocEntry[] = [];
  for (const s of page.sections) {
    out.push({ id: s.id, title: s.title, depth: 2 });
    for (const c of s.children ?? []) {
      out.push({ id: c.id, title: c.title, depth: 3 });
    }
  }
  return out;
}
