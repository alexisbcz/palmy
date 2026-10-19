import { cn } from "~/lib/utils";

export type ChainNode = { depth: number; name: string; note: string };

type TreeNode = ChainNode & { children: TreeNode[] };

function build(nodes: ChainNode[]): TreeNode[] {
  const roots: TreeNode[] = [];
  const stack: TreeNode[] = [];
  for (const n of nodes) {
    const t: TreeNode = { ...n, children: [] };
    while (stack.length && stack[stack.length - 1].depth >= n.depth) stack.pop();
    if (stack.length) stack[stack.length - 1].children.push(t);
    else roots.push(t);
    stack.push(t);
  }
  return roots;
}

/** Firmware, bootloader and kernel are stages; the rest are processes. */
const STAGE = /^(OVMF|limine|Linux)/;

function Node({ n, last }: { n: TreeNode; last: boolean }) {
  const stage = STAGE.test(n.name);
  return (
    <li className="relative pl-6">
      {/* The elbow joining this box to its parent's spine. */}
      <span
        aria-hidden="true"
        className={cn(
          "absolute top-0 left-0 w-4 border-b border-l border-foreground/25",
          "h-[1.375rem] rounded-bl-md",
        )}
      />
      {!last ? (
        <span
          aria-hidden="true"
          className="absolute top-0 bottom-0 left-0 border-l border-foreground/25"
        />
      ) : null}
      <div
        className={cn(
          "inline-flex max-w-full flex-col rounded-lg border px-3 py-1.5",
          stage ? "bg-muted/60" : "bg-background",
        )}
      >
        <code className="text-[0.8125rem] font-semibold break-words">{n.name}</code>
        {n.note ? (
          <span className="text-xs leading-5 text-muted-foreground">{n.note}</span>
        ) : null}
      </div>
      {n.children.length ? (
        <ul className="space-y-2 pt-2">
          {n.children.map((c, i) => (
            <Node key={i} n={c} last={i === n.children.length - 1} />
          ))}
        </ul>
      ) : null}
    </li>
  );
}

/**
 * The boot chain, drawn from the tree in distro/README.md (read at sync time,
 * so the two cannot disagree).
 */
export function BootChain({ nodes }: { nodes: ChainNode[] }) {
  const roots = build(nodes);
  return (
    <figure className="not-prose rounded-xl border bg-muted/20 p-4 sm:p-5">
      <ul className="space-y-2 [&>li]:pl-0 [&>li>span]:hidden">
        {roots.map((r, i) => (
          <Node key={i} n={r} last={i === roots.length - 1} />
        ))}
      </ul>
      <figcaption className="mt-4 text-xs text-muted-foreground">
        Shaded boxes are boot stages; the rest are processes, each started by
        the one above it. Read from the boot chain in{" "}
        <code>distro/README.md</code>.
      </figcaption>
    </figure>
  );
}
