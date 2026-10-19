import type { Route } from "./+types/distro.slug";
import { Shell } from "~/components/shell";
import { GeneratedArticle } from "~/components/generated-page";
import { collectionPages, collectionSidebar } from "~/lib/generated-nav";
import { seo } from "~/lib/seo";

export function meta({ loaderData: data, location }: Route.MetaArgs) {
  if (!data) return [{ title: "Not found — Palmframe" }];
  return seo({ title: data.title, description: data.description, path: location.pathname });
}

export async function loader({ params }: Route.LoaderArgs) {
  const { getPage } = await import("~/lib/docs.server");
  const page = getPage("distro", params.slug);
  if (!page) throw new Response("Not found", { status: 404 });
  return page;
}

export default function DistroPage({ loaderData: page }: Route.ComponentProps) {
  const all = collectionPages("distro");
  const i = all.findIndex((p) => p.slug === page.slug);
  return (
    <Shell sidebar={collectionSidebar("distro")} toc={page.toc}>
      <GeneratedArticle page={page} eyebrow="Distribution" prev={all[i - 1]} next={all[i + 1]} />
    </Shell>
  );
}
