import { PALMY_DOCS } from "~/content/docs-palmy";
import { VISION_DOCS } from "~/content/docs-vision";
import { COMPONENTS } from "~/content/components";
import type { DocPage } from "~/lib/doc";
import { collectionPages } from "~/lib/generated-nav";

export type NavLink = {
  to: string;
  label: string;
  /** Marks a link whose page documents something planned, not built. */
  planned?: boolean;
  /** Shown as a small trailing badge. */
  tag?: string;
};

export type NavGroup = { title: string; links: NavLink[] };

/* -------------------------------------------------------------------------- */
/* Lookups                                                                     */
/* -------------------------------------------------------------------------- */

const PALMY_BY_SLUG = new Map(PALMY_DOCS.map((d) => [d.slug, d]));

/* -------------------------------------------------------------------------- */
/* Sidebars                                                                    */
/* -------------------------------------------------------------------------- */

const PALMY_ORDER: { title: string; slugs: string[] }[] = [
  { title: "Getting started", slugs: ["introduction", "installation"] },
  {
    title: "Concepts",
    slugs: [
      "the-frame-loop",
      "state",
      "identity-and-keys",
      "interaction",
      "classes",
      "widgets",
    ],
  },
  {
    title: "Rendering",
    slugs: ["text", "images", "drawing", "layers"],
  },
  {
    title: "Platform",
    slugs: ["backends", "offscreen-and-testing", "parity"],
  },
  { title: "Reference", slugs: ["limitations", "source-layout"] },
];

export function palmySidebar(): NavGroup[] {
  const groups = PALMY_ORDER.map((g) => ({
    title: g.title,
    links: g.slugs
      .map((slug) => PALMY_BY_SLUG.get(slug))
      .filter((d): d is DocPage => Boolean(d))
      .map((d) => ({ to: `/docs/${d.slug}`, label: d.title })),
  }));

  groups.push({
    title: "Generated reference",
    links: collectionPages("reference").map((p) => ({ to: p.url, label: p.nav })),
  });

  // Anything added to the content file but not placed above still appears,
  // so a new page can never be silently missing from the sidebar.
  const placed = new Set(PALMY_ORDER.flatMap((g) => g.slugs));
  const rest = PALMY_DOCS.filter((d) => !placed.has(d.slug));
  if (rest.length > 0) {
    groups.push({
      title: "More",
      links: rest.map((d) => ({ to: `/docs/${d.slug}`, label: d.title })),
    });
  }
  return groups;
}

/** Short labels, so the rail does not truncate a sentence-long title. */
const PALMY_NAV_LABEL: Record<string, string> = {
  overview: "Overview",
  "ai-in-the-system": "AI in the system",
  identities: "Identities",
  cloud: "The cloud part",
  "palm-cli": "The palm CLI",
  "beyond-linux": "Beyond Linux",
  "the-web": "The web backend",
  devices: "Devices",
  "hard-parts": "The hard parts",
};

export function visionSidebar(): NavGroup[] {
  return [
    {
      title: "Palmy",
      links: VISION_DOCS.map((d) => ({
        to: `/vision/${d.slug}`,
        label: PALMY_NAV_LABEL[d.slug] ?? d.title,
        planned: d.planned,
      })),
    },
    {
      title: "Built on it",
      links: [
        { to: "/apps", label: "The applications" },
        { to: "/components", label: "The widget set" },
        { to: "/docs/introduction", label: "The toolkit" },
      ],
    },
  ];
}

export function componentsSidebar(): NavGroup[] {
  return [
    {
      title: "Overview",
      links: [{ to: "/components", label: "All components" }],
    },
    {
      title: `Components (${COMPONENTS.length})`,
      links: COMPONENTS.map((c) => ({
        to: `/components/${c.slug}`,
        label: c.title,
        tag: c.status === "partial" ? "partial" : undefined,
      })),
    },
  ];
}

/* -------------------------------------------------------------------------- */
/* Top navigation                                                              */
/* -------------------------------------------------------------------------- */

export const TOP_NAV: (NavLink & { match: string })[] = [
  { to: "/distro/overview", label: "Distribution", match: "/distro" },
  { to: "/docs/introduction", label: "palmy", match: "/docs|/reference" },
  { to: "/components", label: "Components", match: "/components" },
  { to: "/apps", label: "Apps", match: "/apps" },
  { to: "/vision/overview", label: "Vision", match: "/vision" },
];
