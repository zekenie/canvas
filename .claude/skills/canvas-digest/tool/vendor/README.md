# Vendored: ELK (elkjs 0.12.0)

`elk.bundled.js` is `lib/elk.bundled.js` of the npm package **elkjs 0.12.0** (https://www.npmjs.com/package/elkjs,
https://github.com/kieler/elkjs), which is the Eclipse Layout Kernel (https://github.com/eclipse/elk) compiled to JavaScript.
It is unmodified: its SHA-256 is `1222e44f953ce7746af23801e723708f8e6f436b8b377a6a5fc7552f34a307b3`.

- Licence: the Eclipse Public License 2.0, whose text is `LICENSE.md` beside it. (elkjs offers it as `EPL-2.0 OR GPL-3.0-or-later`; the
  skill takes the EPL.) The notice is also in the repository's `THIRD_PARTY_NOTICES.md`.
- Why it's here: the skill's layout (`tool/lib/elk.mjs`) runs ELK's layered, stress and rectangle-packing algorithms in the system jsc or node,
  with no install step.
- To update it, replace the file and the licence from a newer elkjs package, change the version and hash here and in
  `THIRD_PARTY_NOTICES.md`, and run `DigestTests`.
