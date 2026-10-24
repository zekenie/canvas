# 06 · The reach on the canvas (optional)

**Commit title:** While the command bar's highlighted command reaches fewer shapes than the selection, the ones it reaches are ringed on the canvas

**Depends on:** [04](04-the-command-bar.md). Optional: decision D11 in the [README](README.md). Worth landing after living with 04 and 05, if the count alone leaves people unsure which shapes a command will change.

## The ask

"some of the selection may not support all the same commands." A row's `3 of 5` says how many; a ring says which.

## What it looks like

```
   ╔════════╗ ╔════════╗ ╔════════╗     ┌─────────┐
   ║ Milk   ║ ║ Eggs   ║ ║ Coffee ║     │ ⧉ Pantry│     ║ the ring: what the highlighted
   ╚════════╝ ╚════════╝ ╚════════╝     └─────────┘       command acts on
   ┌────────────────────────────────────────┐
   │ /▍                           4 shapes  │
   └────────────────────────────────────────┘
    ┌──────────────────────────────────────┐
    │ lock                                 │   (no ring: it reaches all four)
    │▌public                        3 of 4 │   highlighted: the three notes are ringed,
    │ is-a                   type · 3 of 4 │   the reference isn't
    └──────────────────────────────────────┘
```

## Justification

- **The core draws every plugin's outlines in one pass**, and a plugin hands it groups of shapes to ring in a color of its own (`registrar.outlines`, `Outlines.tinted`: "its own colors, a ring a line and a gap further out, 4 view points, for each group a shape is in past the first", `.claude/rules/editor.md`). Neighbors' lights are drawn this way. No plugin strokes outlines itself, so the bar draws nothing either: it says which shapes.
- **The selection's own outline is Selection's**, gray while the bar has the keyboard (`.claude/rules/selection.md`), so a ring in the accent outside it reads as "these".
- **`Outlines` is `Equatable`**: a plugin that hands the same outlines asks for no frame.

## Tactics

1. **`SlashBar`** contributes `registrar.outlines { editor in … }`: while the bar is open and the command it would run is partial (the names list's highlighted row, or, with the list closed, the command on the whole line), its reach as one tinted group (`SlashBarStyle.reachRing`, the accent); else none. Choice rows are left out: which owners a row reaches is the command's (Types' `2 of 3`), and the engine doesn't know it.
2. It asks for a frame as the highlight moves (the list's `onChange`) and as the bar opens and closes; never per keystroke otherwise.

### `Package.swift`

Nothing.

### Tests

- SlashCommandsTests `slashBarTests`: the outlines the plugin hands (the reach of a highlighted partial command; none for one that reaches all, none with the bar closed; following ↑ ↓).
- CompositionTests `slashBarShippedTests`: three notes and a reference, `public` highlighted, drawn to a bitmap: the ring round the notes and not the reference (as `steppingShippedTests` reads the selection's outline from a bitmap).

### Docs (same commit)

- `.claude/rules/slash-commands.md`: the ring.
- `docs/plugin-system.md`, the bar's subsection: this plan's wireframe.

## Verification

- `./test.sh`.
- In the app: three notes and a reference, `/`, ↓ to `public`: the ring, and gone on `lock`; zoomed out, the rings are the skeletons' (the core's rule for outlines there).

## Risks and open questions

- **Two lines round each shape** (the selection's gray, the reach's accent) may be busy on small shapes. Alternatives: dim what isn't reached instead (needs Selection to draw part of its selection fainter, a point of its own), or no ring at all.

## Not in this commit

- Rings for a choice row's reach (`/is-a`'s `2 of 3`): Types' to draw, if wanted.
