import type { Route } from "./+types/reference.slug";
import { Shell } from "~/components/shell";
import { GeneratedArticle } from "~/components/generated-page";
import { collectionPages } from "~/lib/generated-nav";
import { palmySidebar } from "~/lib/nav";
import { seo } from "~/lib/seo";

export function meta({ loaderData: data, location }: Route.MetaArgs) {
  if (!data) return [{ title: "Not found — Palmy" }];
  return seo({ title: data.title, description: data.description, path: location.pathname });
}

export async function loader({ params }: Route.LoaderArgs) {
  const { getPage } = await import("~/lib/docs.server");
  const page = getPage("reference", params.slug);
  if (!page) throw new Response("Not found", { status: 404 });
  return page;
}

export default function ReferencePage({ loaderData: page }: Route.ComponentProps) {
  const all = collectionPages("reference");
  const i = all.findIndex((p) => p.slug === page.slug);
  return (
    <Shell sidebar={palmySidebar()} toc={page.toc}>
      <GeneratedArticle page={page} eyebrow="palmy" prev={all[i - 1]} next={all[i + 1]} />
    </Shell>
  );
}
