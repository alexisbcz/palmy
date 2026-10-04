import type { ReactNode } from "react";
import { Info, TriangleAlert, Lightbulb, Ban } from "lucide-react";
import { cn } from "~/lib/utils";

/* -------------------------------------------------------------------------- */
/* Status                                                                      */
/* -------------------------------------------------------------------------- */

export type Status = "built" | "planned" | "partial" | "absent";

const STATUS_STYLE: Record<Status, string> = {
  built:
    "border-emerald-600/30 bg-emerald-500/10 text-emerald-700 dark:text-emerald-400",
  planned:
    "border-amber-600/30 bg-amber-500/10 text-amber-700 dark:text-amber-400",
  partial: "border-sky-600/30 bg-sky-500/10 text-sky-700 dark:text-sky-400",
  absent: "border-border bg-muted text-muted-foreground",
};

const STATUS_LABEL: Record<Status, string> = {
  built: "Built",
  planned: "Planned",
  partial: "Partial",
  absent: "Not implemented",
};

export function StatusBadge({
  status,
  label,
  className,
}: {
  status: Status;
  label?: string;
  className?: string;
}) {
  return (
    <span
      className={cn(
        "inline-flex shrink-0 items-center gap-1.5 rounded-full border px-2 py-0.5 text-[11px] font-medium whitespace-nowrap",
        STATUS_STYLE[status],
        className,
      )}
    >
      <span
        aria-hidden="true"
        className={cn(
          "size-1.5 rounded-full",
          status === "built" && "bg-emerald-500",
          status === "planned" && "bg-amber-500",
          status === "partial" && "bg-sky-500",
          status === "absent" && "bg-muted-foreground/50",
        )}
      />
      {label ?? STATUS_LABEL[status]}
    </span>
  );
}

/* -------------------------------------------------------------------------- */
/* Callout                                                                     */
/* -------------------------------------------------------------------------- */

const CALLOUT = {
  note: { icon: Info, cls: "border-border bg-muted/50" },
  tip: {
    icon: Lightbulb,
    cls: "border-emerald-600/25 bg-emerald-500/[0.07]",
  },
  warn: {
    icon: TriangleAlert,
    cls: "border-amber-600/25 bg-amber-500/[0.07]",
  },
  planned: {
    icon: Ban,
    cls: "border-amber-600/25 bg-amber-500/[0.07]",
  },
} as const;

export function Callout({
  kind = "note",
  title,
  children,
}: {
  kind?: keyof typeof CALLOUT;
  title?: string;
  children: ReactNode;
}) {
  const { icon: Icon, cls } = CALLOUT[kind];
  return (
    <div className={cn("flex gap-3 rounded-xl border p-4", cls)}>
      <Icon
        className="mt-0.5 size-4 shrink-0 text-muted-foreground"
        aria-hidden="true"
      />
      <div className="min-w-0 space-y-1 text-sm leading-6">
        {title ? <p className="font-semibold">{title}</p> : null}
        <div className="[&_p]:text-sm [&_p]:leading-6 [&>*+*]:mt-2">
          {children}
        </div>
      </div>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Tables                                                                      */
/* -------------------------------------------------------------------------- */

export function DataTable({
  head,
  rows,
  className,
}: {
  head: ReactNode[];
  rows: ReactNode[][];
  className?: string;
}) {
  return (
    <div className={cn("overflow-x-auto rounded-xl border", className)}>
      <table className="w-full text-left text-sm">
        <thead className="bg-muted/50">
          <tr>
            {head.map((h, i) => (
              <th
                key={i}
                className="px-3 py-2 text-xs font-semibold tracking-wide text-muted-foreground uppercase"
              >
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} className="border-t">
              {r.map((c, j) => (
                <td
                  key={j}
                  className="px-3 py-2 align-top text-foreground/85 [&_code]:text-[0.8125em]"
                >
                  {c}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/* -------------------------------------------------------------------------- */
/* Misc                                                                        */
/* -------------------------------------------------------------------------- */

export function Kbd({ children }: { children: ReactNode }) {
  return (
    <kbd className="pointer-events-none inline-flex h-5 items-center gap-1 rounded border bg-muted px-1.5 font-mono text-[10px] font-medium text-muted-foreground select-none">
      {children}
    </kbd>
  );
}

/**
 * Content that lives in a plain string — an app note, a component's gap
 * explanation — still wants to name a procedure or a flag. Backticks in those
 * strings become real code spans rather than being shown as punctuation.
 */
export function Ticks({ children }: { children: string }) {
  const parts = children.split("`");
  return (
    <>
      {parts.map((part, i) =>
        i % 2 === 1 ? (
          <code
            key={i}
            className="rounded border bg-muted px-[0.35em] py-[0.15em] font-mono text-[0.85em]"
          >
            {part}
          </code>
        ) : (
          <span key={i}>{part}</span>
        ),
      )}
    </>
  );
}

export function Lede({ children }: { children: ReactNode }) {
  return (
    <p className="text-base leading-7 text-muted-foreground">{children}</p>
  );
}
