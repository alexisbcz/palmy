import { ImageOff } from "lucide-react";
import { cn } from "~/lib/utils";
import { resolveShot, useShots } from "~/lib/use-shots";

/**
 * A screenshot rendered by palmy, or a labelled placeholder when the file is
 * not there. Never a broken image: the screenshots are produced by a separate
 * process and this site has to be correct while that process is still working.
 */
export function Shot({
  names,
  alt,
  className,
  aspect = "16 / 10",
  note,
}: {
  names: string[];
  alt: string;
  className?: string;
  aspect?: string;
  note?: string;
}) {
  const index = useShots();
  const src = resolveShot(index, names);

  return (
    <div
      className={cn(
        "relative overflow-hidden rounded-xl border bg-muted/40",
        className,
      )}
      style={{ aspectRatio: aspect }}
    >
      {src ? (
        <img
          src={src}
          alt={alt}
          loading="lazy"
          className="size-full object-cover object-top"
        />
      ) : (
        <div className="flex size-full flex-col items-center justify-center gap-2 px-4 text-center">
          <ImageOff
            className="size-5 text-muted-foreground/50"
            aria-hidden="true"
          />
          <p className="text-xs font-medium text-muted-foreground">{alt}</p>
          <p className="text-[11px] text-muted-foreground/70">
            {note ?? "Screenshot not generated yet"}
          </p>
        </div>
      )}
    </div>
  );
}
