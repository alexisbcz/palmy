import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import type { Config } from "@react-router/dev/config";

import { COMPONENTS } from "./app/content/components";

/**
 * Every page here is static text, so the whole site is prerendered at build
 * time and served as files. That is not only cheaper than running a server --
 * it is what makes the screenshots work at all.
 *
 * `app/lib/shots.server.ts` reads `public/shots` off the filesystem. Under SSR
 * on a serverless host that read happens inside the function, where `public/`
 * does not exist: it is served by the CDN and is not in the function bundle.
 * The directory would come back empty and every screenshot on the deployed
 * site would quietly degrade to a placeholder -- while working perfectly in
 * development, which is the worst version of this bug. Prerendering moves the
 * read to build time, where the files are genuinely on disk.
 */

const here = (p: string) => fileURLToPath(new URL(p, import.meta.url));

/**
 * The doc pages live in `.tsx` modules that import components through the `~/`
 * alias, which this config file's loader does not resolve, so they cannot be
 * imported here. Their slugs are read out of the source instead of being
 * duplicated into a list that would drift. A `DocPage` is the only thing in
 * either file with a `slug:` -- sections carry `id:` -- and the counts are
 * asserted below, so a page added without a path fails the build rather than
 * going missing from the site.
 */
function docSlugs(file: string, expected: number): string[] {
  const src = readFileSync(here(file), "utf8");
  const slugs = [...src.matchAll(/^\s*slug:\s*"([^"]+)"/gm)].map((m) => m[1]);
  if (slugs.length !== expected) {
    throw new Error(
      `${file}: found ${slugs.length} doc slugs, expected ${expected}. ` +
        `If a page was added or removed, update the count here so the ` +
        `prerendered path list stays complete.`,
    );
  }
  if (new Set(slugs).size !== slugs.length) {
    throw new Error(`${file}: duplicate doc slug`);
  }
  return slugs;
}

const COMPONENT_SLUGS = COMPONENTS.map((c) => c.slug);
if (COMPONENT_SLUGS.length !== 61) {
  throw new Error(
    `expected 61 components, found ${COMPONENT_SLUGS.length}; update this count`,
  );
}

/**
 * The Markdown-driven pages, from the nav scripts/sync-docs.mjs writes. It is
 * plain JSON, so unlike the .tsx content it can be read here directly.
 */
const generated = JSON.parse(
  readFileSync(here("./app/content/generated/nav.json"), "utf8"),
) as Record<string, { groups: { pages: { url: string }[] }[] }>;
const GENERATED_PATHS = Object.values(generated).flatMap((c) =>
  c.groups.flatMap((g) => g.pages.map((p) => p.url)),
);

const paths = [
  "/",
  "/docs",
  "/palmframe",
  "/components",
  "/apps",
  "/distro",
  "/reference",
  ...GENERATED_PATHS,
  ...docSlugs("./app/content/docs-palmy.tsx", 17).map((s) => `/docs/${s}`),
  ...docSlugs("./app/content/docs-palmframe.tsx", 9).map((s) => `/palmframe/${s}`),
  ...COMPONENT_SLUGS.map((s) => `/components/${s}`),
];

export default {
  ssr: false,
  prerender: () => paths,
} satisfies Config;
