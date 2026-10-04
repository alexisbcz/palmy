import { useCallback, useState } from "react";
import { Check, Copy } from "lucide-react";
import { cn } from "~/lib/utils";

type Lang = "odin" | "tsx" | "bash" | "text" | "css" | "json";

const KEYWORDS: Record<string, string[]> = {
  odin: [
    "package", "import", "proc", "struct", "enum", "union", "for", "in", "if",
    "else", "switch", "case", "return", "defer", "using", "when", "break",
    "continue", "do", "distinct", "cast", "transmute", "or_else", "or_return",
    "true", "false", "nil", "map", "bit_set", "matrix", "context", "foreign",
  ],
  tsx: [
    "import", "from", "export", "default", "const", "let", "var", "function",
    "return", "if", "else", "for", "while", "type", "interface", "class",
    "extends", "new", "async", "await", "true", "false", "null", "undefined",
    "as", "of", "in",
  ],
  bash: [
    "if", "then", "fi", "for", "in", "do", "done", "while", "case", "esac",
    "export", "local", "function", "echo", "cd", "set",
  ],
  css: [],
  json: ["true", "false", "null"],
  text: [],
};

type Tok = { t: string; k: string | null };

/**
 * A deliberately small highlighter. A full grammar engine would be a megabyte
 * of JavaScript for a docs site that shows at most forty lines at a time, so
 * this tokenises the five things that actually carry meaning in a snippet:
 * comments, strings, numbers, keywords and the name being declared.
 */
function tokenize(src: string, lang: Lang): Tok[] {
  if (lang === "text") return [{ t: src, k: null }];
  const kw = new Set(KEYWORDS[lang] ?? []);
  const out: Tok[] = [];
  let i = 0;
  let buf = "";
  const flush = () => {
    if (buf) out.push({ t: buf, k: null });
    buf = "";
  };
  const lineComment = lang === "bash" ? "#" : "//";

  while (i < src.length) {
    const rest = src.slice(i);

    if (rest.startsWith(lineComment)) {
      flush();
      const nl = rest.indexOf("\n");
      const end = nl === -1 ? rest.length : nl;
      out.push({ t: rest.slice(0, end), k: "comment" });
      i += end;
      continue;
    }
    if (lang !== "bash" && rest.startsWith("/*")) {
      flush();
      const close = rest.indexOf("*/");
      const end = close === -1 ? rest.length : close + 2;
      out.push({ t: rest.slice(0, end), k: "comment" });
      i += end;
      continue;
    }
    const q = src[i];
    if (q === '"' || q === "'" || q === "`") {
      flush();
      let j = i + 1;
      while (j < src.length && src[j] !== q) {
        if (src[j] === "\\") j++;
        j++;
      }
      out.push({ t: src.slice(i, Math.min(j + 1, src.length)), k: "string" });
      i = j + 1;
      continue;
    }
    const idm = /^[A-Za-z_][A-Za-z0-9_]*/.exec(rest);
    if (idm) {
      flush();
      const word = idm[0];
      const after = rest.slice(word.length);
      let k: string | null = null;
      if (kw.has(word)) k = "keyword";
      else if (/^\s*\(/.test(after)) k = "fn";
      else if (/^[A-Z][A-Za-z0-9_]*$/.test(word)) k = "type";
      out.push({ t: word, k });
      i += word.length;
      continue;
    }
    const num = /^0[xb][0-9a-fA-F_]+|^\d[\d_.]*/.exec(rest);
    if (num) {
      flush();
      out.push({ t: num[0], k: "number" });
      i += num[0].length;
      continue;
    }
    buf += src[i];
    i++;
  }
  flush();
  return out;
}

const CLASS: Record<string, string> = {
  comment: "text-muted-foreground italic",
  string: "text-emerald-700 dark:text-emerald-400",
  number: "text-amber-700 dark:text-amber-400",
  keyword: "text-violet-700 dark:text-violet-400",
  fn: "text-sky-700 dark:text-sky-400",
  type: "text-cyan-700 dark:text-cyan-300",
};

export function CopyButton({
  value,
  className,
  label = "Copy code",
}: {
  value: string;
  className?: string;
  label?: string;
}) {
  const [done, setDone] = useState(false);
  const copy = useCallback(() => {
    const write =
      typeof navigator !== "undefined" && navigator.clipboard
        ? navigator.clipboard.writeText(value)
        : Promise.reject(new Error("no clipboard"));
    write
      .then(() => {
        setDone(true);
        setTimeout(() => setDone(false), 1600);
      })
      .catch(() => {
        // Clipboard access is denied in some contexts; say nothing rather
        // than claiming a copy that did not happen.
      });
  }, [value]);

  return (
    <button
      type="button"
      onClick={copy}
      aria-label={label}
      title={label}
      className={cn(
        "inline-flex size-7 shrink-0 items-center justify-center rounded-md border border-border/60 bg-background/80 text-muted-foreground backdrop-blur transition hover:bg-accent hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none",
        className,
      )}
    >
      {done ? (
        <Check className="size-3.5 text-emerald-600 dark:text-emerald-400" />
      ) : (
        <Copy className="size-3.5" />
      )}
    </button>
  );
}

export function CodeBlock({
  code,
  lang = "odin",
  title,
  className,
  copy = true,
  maxHeight,
}: {
  code: string;
  lang?: Lang;
  title?: string;
  className?: string;
  copy?: boolean;
  maxHeight?: number;
}) {
  const src = code.replace(/^\n+/, "").replace(/\s+$/, "");
  const toks = tokenize(src, lang);
  return (
    <figure
      className={cn(
        "group relative w-full max-w-full min-w-0 overflow-hidden rounded-xl border bg-muted/40",
        className,
      )}
    >
      {title ? (
        <figcaption className="flex items-center gap-2 border-b bg-muted/60 px-4 py-2 font-mono text-xs text-muted-foreground">
          {title}
        </figcaption>
      ) : null}
      <div className="absolute top-2 right-2 z-10 flex items-center gap-1">
        {!title ? (
          <span className="hidden rounded border border-border/60 bg-background/70 px-1.5 py-0.5 font-mono text-[10px] text-muted-foreground backdrop-blur sm:inline">
            {lang}
          </span>
        ) : null}
        {copy ? <CopyButton value={src} /> : null}
      </div>
      <pre
        className="thin-scroll overflow-x-auto px-4 py-4 text-[0.8125rem] leading-6"
        style={maxHeight ? { maxHeight, overflowY: "auto" } : undefined}
      >
        <code className="font-mono">
          {toks.map((t, n) =>
            t.k ? (
              <span key={n} className={CLASS[t.k]}>
                {t.t}
              </span>
            ) : (
              <span key={n}>{t.t}</span>
            ),
          )}
        </code>
      </pre>
    </figure>
  );
}
