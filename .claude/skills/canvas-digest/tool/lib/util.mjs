// Small pure helpers. No Node APIs: this runs under jsc and node alike.

/** Code-unit order: the same in every engine, unlike localeCompare. */
export const byTitle = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

export function median(xs) {
  if (!xs.length) return 0;
  const a = xs.slice().sort((p, q) => p - q);
  const m = a.length >> 1;
  return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2;
}

/** The tool's folder (the one above lib/), from this module's own url: the same in jsc and node. */
export const TOOL_DIR = decodeURIComponent(import.meta.url.replace(/^file:\/\//, '').replace(/\/lib\/util\.mjs$/, ''));
