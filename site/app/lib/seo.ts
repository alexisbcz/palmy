/**
 * Every page's <head>: title, description, canonical URL, Open Graph and
 * Twitter cards. The social image for a path is /og/<path>.png, rendered at
 * build time by scripts/postbuild.mjs from the same title and description.
 */

export const SITE_URL = (
  import.meta.env.VITE_SITE_URL ?? "https://palmy-os.vercel.app"
).replace(/\/$/, "");
export const SITE_NAME = "Palmy";
export const REPO_URL = "https://github.com/alexisbcz/palmy";

/** /distro/quick-start -> distro--quick-start; / -> index. */
export function ogSlug(path: string) {
  const p = path.replace(/^\/+|\/+$/g, "");
  return p ? p.replace(/\//g, "--") : "index";
}

export function seo({
  title,
  description,
  path,
  fullTitle = false,
}: {
  title: string;
  description: string;
  path: string;
  /** When false, " — Palmy" is appended. */
  fullTitle?: boolean;
}) {
  const t = fullTitle ? title : `${title} — ${SITE_NAME}`;
  const url = `${SITE_URL}${path === "/" ? "/" : path.replace(/\/$/, "")}`;
  const image = `${SITE_URL}/og/${ogSlug(path)}.png`;
  return [
    { title: t },
    { name: "description", content: description },
    { tagName: "link", rel: "canonical", href: url },
    { property: "og:type", content: path === "/" ? "website" : "article" },
    { property: "og:site_name", content: SITE_NAME },
    { property: "og:title", content: title },
    { property: "og:description", content: description },
    { property: "og:url", content: url },
    { property: "og:image", content: image },
    { property: "og:image:width", content: "1200" },
    { property: "og:image:height", content: "630" },
    { name: "twitter:card", content: "summary_large_image" },
    { name: "twitter:title", content: title },
    { name: "twitter:description", content: description },
    { name: "twitter:image", content: image },
  ];
}
