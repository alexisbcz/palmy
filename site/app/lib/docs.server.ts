

/**
 * The pages scripts/sync-docs.mjs generated. Imported eagerly, but only from
 * route loaders, which run at build time (every page is prerendered), so none
 * of this reaches a browser bundle; a browser gets one page's data at a time.
 */
export type GeneratedPage = {
  url: string;
  slug: string;
  collection: string;
  group: string;
  title: string;
  description: string;
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

const modules = import.meta.glob<GeneratedPage>("../content/generated/pages/*.json", {
  eager: true,
  import: "default",
});

const BY_KEY = new Map<string, GeneratedPage>();
for (const page of Object.values(modules)) {
  BY_KEY.set(`${page.collection}/${page.slug}`, page);
}

export function getPage(collection: string, slug: string | undefined) {
  return slug ? BY_KEY.get(`${collection}/${slug}`) : undefined;
}
