import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

/**
 * The screenshots in `public/shots` are rendered by palmy itself, by a
 * separate process that may still be running. So the directory is read per
 * request rather than baked in at build time: a shot that appears later shows
 * up without a rebuild, and a shot that is not there yet degrades to a
 * labelled placeholder instead of a broken image.
 */
const DIR = join(process.cwd(), "public", "shots");
const IMAGE = /\.(png|jpg|jpeg|webp|avif|gif)$/i;

export function listShots(): string[] {
  try {
    if (!existsSync(DIR)) return [];
    return readdirSync(DIR)
      .filter((f) => IMAGE.test(f))
      .sort();
  } catch {
    return [];
  }
}
