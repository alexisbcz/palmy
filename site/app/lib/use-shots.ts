import { useRouteLoaderData } from "react-router";

export type ShotIndex = {
  files: string[];
  /** basename without extension -> public URL */
  byName: Record<string, string>;
};

export function buildShotIndex(files: string[]): ShotIndex {
  const byName: Record<string, string> = {};
  for (const f of files) {
    const base = f.replace(/\.[^.]+$/, "");
    // First match wins so the sorted order is deterministic.
    if (!(base in byName)) byName[base] = `/shots/${f}`;
  }
  return { files, byName };
}

export function useShots(): ShotIndex {
  const data = useRouteLoaderData("root") as { shots?: ShotIndex } | undefined;
  return data?.shots ?? { files: [], byName: {} };
}

/**
 * Resolve a shot by trying a list of candidate basenames in order. Component
 * and app pages ask for several spellings because the generator and this site
 * were written in parallel.
 */
export function resolveShot(
  index: ShotIndex,
  candidates: string[],
): string | null {
  for (const c of candidates) {
    const hit = index.byName[c];
    if (hit) return hit;
  }
  return null;
}
