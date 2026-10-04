import { useEffect, useState, type ReactNode } from "react";

/**
 * The 61 previews pull in a charting library, a date picker, a carousel and a
 * command menu between them. Importing that eagerly puts all of it on every
 * component page, so it is fetched after the page is interactive instead.
 */
export function PreviewHost({ slug }: { slug: string }) {
  const [node, setNode] = useState<ReactNode | null>(null);
  const [state, setState] = useState<"loading" | "ready" | "none" | "failed">(
    "loading",
  );

  useEffect(() => {
    let live = true;
    import("~/content/previews")
      .then((m) => {
        if (!live) return;
        const fn = m.PREVIEWS[slug];
        if (!fn) {
          setState("none");
          return;
        }
        setNode(fn());
        setState("ready");
      })
      .catch(() => {
        if (live) setState("failed");
      });
    return () => {
      live = false;
    };
  }, [slug]);

  if (state === "loading") {
    return (
      <div className="h-6 w-32 animate-pulse rounded bg-muted" aria-hidden />
    );
  }
  if (state === "none") {
    return (
      <p className="text-sm text-muted-foreground">
        No live React preview for this one. The Odin and React tabs show the
        source.
      </p>
    );
  }
  if (state === "failed") {
    return (
      <p className="text-sm text-muted-foreground">
        The preview could not be loaded. The Odin and React tabs show the
        source.
      </p>
    );
  }
  return <>{node}</>;
}
