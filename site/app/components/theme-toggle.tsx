import { useCallback, useEffect, useState } from "react";
import { MoonIcon, SunIcon } from "lucide-react";
import { cn } from "~/lib/utils";

const KEY = "palmframe-theme";

/**
 * Inlined into <head> so the first paint is already the right theme. Without
 * it the page flashes white before the script that reads the preference runs,
 * which is the one bug every hand-rolled dark mode ships with.
 */
export const THEME_SCRIPT = `(function(){try{
var s=localStorage.getItem(${JSON.stringify(KEY)});
var d=s?s==="dark":window.matchMedia("(prefers-color-scheme: dark)").matches;
var r=document.documentElement;
r.classList.toggle("dark",d);
r.dataset.theme=d?"dark":"light";
r.style.colorScheme=d?"dark":"light";
}catch(e){}})();`;

function apply(dark: boolean) {
  const r = document.documentElement;
  r.classList.toggle("dark", dark);
  r.dataset.theme = dark ? "dark" : "light";
  r.style.colorScheme = dark ? "dark" : "light";
  try {
    localStorage.setItem(KEY, dark ? "dark" : "light");
  } catch {
    // Private windows refuse writes. The toggle still works for this page.
  }
}

export function ThemeToggle({ className }: { className?: string }) {
  // Starts undefined so the server and the first client render agree; the
  // inline script has already set the real theme on <html>.
  const [dark, setDark] = useState<boolean | null>(null);

  useEffect(() => {
    setDark(document.documentElement.classList.contains("dark"));
  }, []);

  const toggle = useCallback(() => {
    const next = !document.documentElement.classList.contains("dark");
    apply(next);
    setDark(next);
  }, []);

  return (
    <button
      type="button"
      onClick={toggle}
      aria-label="Toggle dark mode"
      title="Toggle dark mode"
      className={cn(
        "inline-flex size-8 items-center justify-center rounded-md text-muted-foreground transition hover:bg-accent hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none",
        className,
      )}
    >
      {dark === null ? (
        <SunIcon className="size-4 opacity-0" />
      ) : dark ? (
        <SunIcon className="size-4" />
      ) : (
        <MoonIcon className="size-4" />
      )}
    </button>
  );
}
