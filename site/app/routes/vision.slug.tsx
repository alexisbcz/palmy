import type { Route } from "./+types/palmy.slug";
import { seo } from "~/lib/seo";
import { Shell } from "~/components/shell";
import { DocArticle } from "~/components/doc-page";
import { tocOf } from "~/lib/doc";
import { VISION_DOCS } from "~/content/docs-vision";
import { visionSidebar } from "~/lib/nav";

export function meta({ loaderData: data, location }: Route.MetaArgs) {
  if (!data) return [{ title: "Not found — Palmy" }];
  return seo({ title: data.title, description: data.description, path: location.pathname });
}

export function loader({ params }: Route.LoaderArgs) {
  const i = VISION_DOCS.findIndex((d) => d.slug === params.slug);
  if (i === -1) {
    throw new Response("Not found", { status: 404 });
  }
  const page = VISION_DOCS[i];
  return { index: i, title: page.title, description: page.description };
}

export default function PalmyPage({ loaderData }: Route.ComponentProps) {
  const page = VISION_DOCS[loaderData.index];
  const prev = VISION_DOCS[loaderData.index - 1];
  const next = VISION_DOCS[loaderData.index + 1];

  return (
    <Shell sidebar={visionSidebar()} toc={tocOf(page)}>
      <DocArticle
        page={page}
        base="/vision/overview"
        eyebrow="Palmy"
        prev={
          prev
            ? {
                to: `/vision/${prev.slug}`,
                label: prev.slug === "overview" ? "Overview" : prev.title,
              }
            : undefined
        }
        next={
          next
            ? {
                to: `/vision/${next.slug}`,
                label: next.slug === "overview" ? "Overview" : next.title,
              }
            : undefined
        }
      />
    </Shell>
  );
}
