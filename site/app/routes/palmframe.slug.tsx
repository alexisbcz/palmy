import type { Route } from "./+types/palmframe.slug";
import { seo } from "~/lib/seo";
import { Shell } from "~/components/shell";
import { DocArticle } from "~/components/doc-page";
import { tocOf } from "~/lib/doc";
import { PALMFRAME_DOCS } from "~/content/docs-palmframe";
import { palmframeSidebar } from "~/lib/nav";

export function meta({ loaderData: data, location }: Route.MetaArgs) {
  if (!data) return [{ title: "Not found — Palmframe" }];
  return seo({ title: data.title, description: data.description, path: location.pathname });
}

export function loader({ params }: Route.LoaderArgs) {
  const i = PALMFRAME_DOCS.findIndex((d) => d.slug === params.slug);
  if (i === -1) {
    throw new Response("Not found", { status: 404 });
  }
  const page = PALMFRAME_DOCS[i];
  return { index: i, title: page.title, description: page.description };
}

export default function PalmframePage({ loaderData }: Route.ComponentProps) {
  const page = PALMFRAME_DOCS[loaderData.index];
  const prev = PALMFRAME_DOCS[loaderData.index - 1];
  const next = PALMFRAME_DOCS[loaderData.index + 1];

  return (
    <Shell sidebar={palmframeSidebar()} toc={tocOf(page)}>
      <DocArticle
        page={page}
        base="/palmframe/overview"
        eyebrow="Palmframe"
        prev={
          prev
            ? {
                to: `/palmframe/${prev.slug}`,
                label: prev.slug === "overview" ? "Overview" : prev.title,
              }
            : undefined
        }
        next={
          next
            ? {
                to: `/palmframe/${next.slug}`,
                label: next.slug === "overview" ? "Overview" : next.title,
              }
            : undefined
        }
      />
    </Shell>
  );
}
