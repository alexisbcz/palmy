import type { ComponentProps, ReactNode } from "react";
import { Fragment, jsx, jsxs } from "react/jsx-runtime";
import { Link } from "react-router";
import { toJsxRuntime, type Components } from "hast-util-to-jsx-runtime";
import type { Element, ElementContent, Root } from "hast";
import { ArrowRightIcon, LinkIcon } from "lucide-react";

import { CodeBlock, Pre } from "~/components/docs/components/codeblock";
import { Callout, type CalloutType } from "~/components/docs/components/callout";
import { BootChain, type ChainNode } from "~/components/boot-chain";
import { Dialog, DialogContent, DialogTitle, DialogTrigger } from "~/components/ui/dialog";
import { cn } from "~/lib/utils";

/**
 * The wire format scripts/sync-docs.mjs writes: a string is a text node, an
 * array is [tagName, properties | 0, ...children].
 */
export type Compact = string | [string, Record<string, unknown> | 0, ...Compact[]];

function expand(c: Compact): ElementContent {
  if (typeof c === "string") return { type: "text", value: c };
  const [tagName, props, ...kids] = c;
  return {
    type: "element",
    tagName,
    properties: (props || {}) as Element["properties"],
    children: kids.map(expand),
  };
}

function toRoot(c: Compact): Root {
  if (typeof c === "string" || c[0] !== "#root") throw new Error("not a page root");
  return { type: "root", children: c.slice(2).map((k) => expand(k as Compact)) };
}

/* -------------------------------------------------------------------------- */

function Heading({
  as: Tag,
  id,
  children,
  ...props
}: { as: "h2" | "h3" | "h4" } & ComponentProps<"h2">) {
  return (
    <Tag id={id} className="group" {...props}>
      {children}
      {id ? (
        <a
          href={`#${id}`}
          aria-label="Link to this section"
          className="ml-2 inline-flex align-middle text-muted-foreground opacity-0 transition group-hover:opacity-100 focus-visible:opacity-100"
        >
          <LinkIcon className="size-3.5" />
        </a>
      ) : null}
    </Tag>
  );
}

function A({ href = "", children, ...props }: ComponentProps<"a">) {
  if (href.startsWith("/")) {
    return (
      <Link to={href} {...props}>
        {children}
      </Link>
    );
  }
  if (href.startsWith("#")) {
    return (
      <a href={href} {...props}>
        {children}
      </a>
    );
  }
  return (
    <a href={href} target="_blank" rel="noreferrer" {...props}>
      {children}
    </a>
  );
}

/** A screenshot, captioned with its alt text, that opens full size. */
function Img({ src, alt, width, height }: ComponentProps<"img">) {
  return (
    <Dialog>
      <DialogTrigger
        render={
          <button
            type="button"
            className="block w-full cursor-zoom-in overflow-hidden rounded-xl border bg-muted/30 text-left"
            aria-label={`Enlarge: ${alt ?? "image"}`}
          />
        }
      >
        <img
          src={src}
          alt={alt}
          width={width}
          height={height}
          loading="lazy"
          decoding="async"
          className="h-auto w-full"
        />
      </DialogTrigger>
      <DialogContent className="max-w-[min(96vw,1400px)] p-2 sm:max-w-[min(96vw,1400px)]">
        <DialogTitle className="sr-only">{alt}</DialogTitle>
        <img src={src} alt={alt} className="h-auto w-full rounded-lg" />
        {alt ? <p className="px-2 pb-1 text-sm text-muted-foreground">{alt}</p> : null}
      </DialogContent>
    </Dialog>
  );
}

/**
 * A paragraph that holds nothing but an image is a figure: the alt text,
 * which in this repository is written as a caption, is shown under it.
 */
function P({ node, children, ...props }: ComponentProps<"p"> & { node?: Element }) {
  const only = node?.children.filter((c) => !(c.type === "text" && !c.value.trim()));
  if (only?.length === 1 && only[0].type === "element" && only[0].tagName === "img") {
    const alt = String(only[0].properties.alt ?? "");
    return (
      <figure className="space-y-2">
        {children}
        {alt ? <figcaption className="text-sm leading-6 text-muted-foreground">{alt}</figcaption> : null}
      </figure>
    );
  }
  return <p {...props}>{children}</p>;
}

function Table({ children, ...props }: ComponentProps<"table">) {
  return (
    <div className="md-table thin-scroll overflow-x-auto rounded-xl border">
      <table {...props}>{children}</table>
    </div>
  );
}

function Cards({ node }: { node?: Element }) {
  // :::cards holds one list; each item is "[Title](/url): description".
  const list = node?.children.find((c): c is Element => c.type === "element" && c.tagName === "ul");
  const items = (list?.children ?? []).filter(
    (c): c is Element => c.type === "element" && c.tagName === "li",
  );
  return (
    <div className="not-prose grid gap-3 sm:grid-cols-2">
      {items.map((li, i) => {
        const flat = li.children.flatMap((c) =>
          c.type === "element" && c.tagName === "p" ? c.children : [c],
        );
        const a = flat.find((c): c is Element => c.type === "element" && c.tagName === "a");
        const rest = flat
          .filter((c) => c !== a)
          .map((c) => (c.type === "text" ? c.value : c.type === "element" ? textOf(c) : ""))
          .join("")
          .replace(/^\s*[:—-]\s*/, "")
          .trim();
        const href = String(a?.properties.href ?? "#");
        return (
          <Link
            key={i}
            to={href}
            className="group flex flex-col gap-1 rounded-xl border p-4 no-underline transition hover:bg-accent/40"
          >
            <span className="flex items-center gap-1.5 text-sm font-medium text-foreground">
              {a ? textOf(a) : href}
              <ArrowRightIcon className="size-3.5 -translate-x-1 opacity-0 transition group-hover:translate-x-0 group-hover:opacity-100" />
            </span>
            <span className="text-sm leading-6 text-muted-foreground">{rest}</span>
          </Link>
        );
      })}
    </div>
  );
}

function textOf(n: ElementContent): string {
  if (n.type === "text") return n.value;
  if (n.type === "element") return n.children.map(textOf).join("");
  return "";
}

function Div({
  node,
  children,
  ...props
}: ComponentProps<"div"> & { node?: Element; [k: `data-${string}`]: unknown }) {
  const p = props as Record<string, unknown>;
  if (p["data-callout"] !== undefined) {
    const title = String(p["data-title"] ?? "");
    return (
      <Callout type={String(p["data-callout"]) as CalloutType} title={title || undefined}>
        {children}
      </Callout>
    );
  }
  if (p["data-component"] === "boot-chain") {
    const props = JSON.parse(String(p["data-props"])) as { nodes: ChainNode[] };
    return <BootChain nodes={props.nodes} />;
  }
  if (p["data-cards"] !== undefined) return <Cards node={node} />;
  return <div {...props}>{children}</div>;
}

function CodePre({ children, ...props }: ComponentProps<"pre">) {
  const p = props as Record<string, unknown>;
  const title = p["data-title"] ? String(p["data-title"]) : undefined;
  return (
    <CodeBlock title={title} className="my-0">
      <Pre className={props.className}>{children}</Pre>
    </CodeBlock>
  );
}

/** `passNode` hands every component its hast node; most must not pass it on. */
type WithNode<P> = P & { node?: Element };
function dropNode<P extends object>(C: (p: P) => ReactNode) {
  return function Wrapped({ node: _node, ...rest }: WithNode<P>) {
    return C(rest as P);
  };
}

const COMPONENTS: Partial<Components> = {
  a: dropNode(A),
  img: dropNode(Img),
  p: P as Components["p"],
  pre: dropNode(CodePre),
  table: dropNode(Table),
  div: Div as Components["div"],
  h2: dropNode((props: ComponentProps<"h2">) => <Heading as="h2" {...props} />),
  h3: dropNode((props: ComponentProps<"h3">) => <Heading as="h3" {...props} />),
  h4: dropNode((props: ComponentProps<"h4">) => <Heading as="h4" {...props} />),
};

export function Markdown({ tree, className }: { tree: Compact; className?: string }): ReactNode {
  const content = toJsxRuntime(toRoot(tree), {
    Fragment,
    jsx,
    jsxs,
    components: COMPONENTS,
    passNode: true,
  });
  return <div className={cn("prose-doc md-doc", className)}>{content}</div>;
}
