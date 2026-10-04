import {
  isRouteErrorResponse,
  Link,
  Links,
  Meta,
  Outlet,
  Scripts,
  ScrollRestoration,
} from "react-router";

import type { Route } from "./+types/root";
import "./app.css";
import { THEME_SCRIPT } from "~/components/theme-toggle";
import { SiteHeader, SiteFooter } from "~/components/shell";
import { buildShotIndex } from "~/lib/use-shots";

const FAVICON =
  "data:image/svg+xml," +
  encodeURIComponent(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">' +
      '<rect width="32" height="32" rx="7" fill="#0a0a0a"/>' +
      '<text x="16" y="23" font-family="system-ui,sans-serif" font-size="20"' +
      ' font-weight="700" fill="#fafafa" text-anchor="middle">P</text>' +
      "</svg>",
  );

export const links: Route.LinksFunction = () => [
  { rel: "icon", href: FAVICON, type: "image/svg+xml" },
];

export async function loader() {
  // Imported here rather than at module scope so the browser bundle never
  // pulls in node:fs.
  const { listShots } = await import("~/lib/shots.server");
  return { shots: buildShotIndex(listShots()) };
}

export function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <Meta />
        <Links />
        <script dangerouslySetInnerHTML={{ __html: THEME_SCRIPT }} />
      </head>
      <body className="min-h-screen bg-background text-foreground antialiased">
        {children}
        <ScrollRestoration />
        <Scripts />
      </body>
    </html>
  );
}

export default function App() {
  return <Outlet />;
}

export function ErrorBoundary({ error }: Route.ErrorBoundaryProps) {
  let heading = "Something went wrong";
  let detail = "An unexpected error occurred.";

  if (isRouteErrorResponse(error)) {
    heading = error.status === 404 ? "Page not found" : `Error ${error.status}`;
    detail =
      error.status === 404
        ? "That page is not part of this documentation."
        : error.statusText || detail;
  } else if (import.meta.env.DEV && error instanceof Error) {
    detail = error.message;
  }

  return (
    <div className="min-h-screen">
      <SiteHeader />
      <main className="mx-auto max-w-2xl px-4 py-24 text-center">
        <h1 className="text-3xl font-bold tracking-tight">{heading}</h1>
        <p className="mt-3 text-muted-foreground">{detail}</p>
        <div className="mt-8 flex flex-wrap justify-center gap-3 text-sm">
          <Link
            to="/"
            className="rounded-md border px-3 py-1.5 hover:bg-accent"
          >
            Home
          </Link>
          <Link
            to="/docs/introduction"
            className="rounded-md border px-3 py-1.5 hover:bg-accent"
          >
            palmy docs
          </Link>
          <Link
            to="/components"
            className="rounded-md border px-3 py-1.5 hover:bg-accent"
          >
            Components
          </Link>
        </div>
      </main>
      <SiteFooter />
    </div>
  );
}
