// Small pure helpers. No Node APIs: this runs under jsc and node alike.

/** Code-unit order: the same in every engine, unlike localeCompare. */
export const byTitle = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

export function fold(s) {
  return String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
}

export function median(xs) {
  if (!xs.length) return 0;
  const a = xs.slice().sort((p, q) => p - q);
  const m = a.length >> 1;
  return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2;
}

/** A draw string literal: only \" \\ \n \t are escapes draw reads. */
export function lit(s) {
  let out = '"';
  for (const ch of String(s)) {
    const c = ch.codePointAt(0);
    if (ch === '"') out += '\\"';
    else if (ch === '\\') out += '\\\\';
    else if (ch === '\n') out += '\\n';
    else if (ch === '\t') out += '\\t';
    else if (c < 32) out += ' ';
    else out += ch;
  }
  return out + '"';
}

export const q = lit;

export function slug(s) {
  return String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'board';
}

/** A small deterministic generator (mulberry32). */
export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export const round1 = (x) => Math.round(x * 10) / 10;
export const pad2 = (n) => (n < 10 ? '0' + n : '' + n);

/** The tool's folder (the one above lib/), from this module's own url: the same in jsc and node. */
export const TOOL_DIR = decodeURIComponent(import.meta.url.replace(/^file:\/\//, '').replace(/\/lib\/util\.mjs$/, ''));
