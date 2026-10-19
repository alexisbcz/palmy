import nav from "~/content/generated/nav.json";
import type { NavGroup } from "~/lib/nav";

export type GenNavPage = {
  slug: string;
  url: string;
  title: string;
  nav: string;
  description: string;
};
export type GenCollection = {
  base: string;
  title: string;
  groups: { title: string; pages: GenNavPage[] }[];
};

export const GENERATED = nav as unknown as Record<"distro" | "reference", GenCollection>;

export function collectionPages(c: keyof typeof GENERATED): GenNavPage[] {
  return GENERATED[c].groups.flatMap((g) => g.pages);
}

export function collectionSidebar(c: keyof typeof GENERATED): NavGroup[] {
  return GENERATED[c].groups.map((g) => ({
    title: g.title,
    links: g.pages.map((p) => ({ to: p.url, label: p.nav })),
  }));
}
