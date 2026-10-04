import { useState } from "react";
import { cn } from "~/lib/utils";
import { CodeBlock, CopyButton } from "~/components/code-block";
import { PreviewHost } from "~/components/preview-host";

type Tab = { key: string; label: string };

/**
 * The preview pattern: a rendered example, then the source behind it. The
 * Odin tab comes first because that is what this project is — the React is
 * there so the two can be read against each other.
 */
export function ComponentPreview({
  slug,
  odin,
  react,
}: {
  slug: string;
  odin: string;
  react: string;
}) {
  const tabs: Tab[] = [
    { key: "preview", label: "Preview" },
    { key: "odin", label: "Odin" },
    { key: "react", label: "React" },
  ];
  const [tab, setTab] = useState(tabs[0].key);
  const code = tab === "react" ? react : odin;

  return (
    <div className="not-prose">
      <div
        role="tablist"
        aria-label="Example source"
        className="flex items-center gap-1 border-b"
      >
        {tabs.map((t) => (
          <button
            key={t.key}
            type="button"
            role="tab"
            aria-selected={tab === t.key}
            onClick={() => setTab(t.key)}
            className={cn(
              "-mb-px border-b-2 px-3 py-2 text-sm transition",
              tab === t.key
                ? "border-foreground font-medium text-foreground"
                : "border-transparent text-muted-foreground hover:text-foreground",
            )}
          >
            {t.label}
          </button>
        ))}
        {tab !== "preview" ? (
          <CopyButton
            value={code}
            className="ml-auto mb-1"
            label={`Copy ${tab === "react" ? "React" : "Odin"} example`}
          />
        ) : null}
      </div>

      <div className="pt-4">
        {tab === "preview" ? (
          <div className="flex min-h-64 w-full items-center justify-center overflow-hidden rounded-xl border p-8">
            <PreviewHost slug={slug} />
          </div>
        ) : (
          <CodeBlock
            code={code}
            lang={tab === "react" ? "tsx" : "odin"}
            copy={false}
          />
        )}
      </div>
    </div>
  );
}
