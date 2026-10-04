import type { Route } from "./+types/docs.slug";
import { Shell } from "~/components/shell";
import { DocArticle } from "~/components/doc-page";
import { tocOf } from "~/lib/doc";
import { PALMY_DOCS } from "~/content/docs-palmy";
import { palmySidebar } from "~/lib/nav";

export function meta({ loaderData: data }: Route.MetaArgs) {
  if (!data) return [{ title: "Not found — palmy" }];
  return [
    { title: `${data.title} — palmy` },
    { name: "description", content: data.description },
  ];
}

export function loader({ params }: Route.LoaderArgs) {
  const i = PALMY_DOCS.findIndex((d) => d.slug === params.slug);
  if (i === -1) {
    throw new Response("Not found", { status: 404 });
  }
  const page = PALMY_DOCS[i];
  return {
    index: i,
    title: page.title,
    description: page.description,
  };
}

export default function DocsPage({ loaderData }: Route.ComponentProps) {
  const page = PALMY_DOCS[loaderData.index];
  const prev = PALMY_DOCS[loaderData.index - 1];
  const next = PALMY_DOCS[loaderData.index + 1];

  return (
    <Shell sidebar={palmySidebar()} toc={tocOf(page)}>
      <DocArticle
        page={page}
        base="/docs/introduction"
        eyebrow="palmy"
        prev={prev ? { to: `/docs/${prev.slug}`, label: prev.title } : undefined}
        next={next ? { to: `/docs/${next.slug}`, label: next.title } : undefined}
      />
    </Shell>
  );
}
