# 03 · A card that isn't about what a shape draws shows at any zoom

**Commit title:** A card may say it isn't about what a shape draws, and then shows and stays at any zoom, where cards about a shape's content stay refused among skeletons

**Depends on:** nothing. Nothing ships that uses it until [04](04-the-command-bar.md).

## The ask

"beneath your selection you have a slash command that you're typing". The command bar is a core card ([04](04-the-command-bar.md)), and it has to work zoomed out: forty notes selected at 20%, `/color red`. Today no card can show there.

## Justification

- **The core refuses and closes every card among skeletons.** `showCard` returns false for a card about a shape drawn as a skeleton and, for a card about none, while `drawsSkeletons` (`Sources/Canvas/Editor/Cards.swift:96`, `:99`); `cardFollowsCamera` closes a showing one `.skeleton` as the zoom crosses the level (`:165`). That's right for every card so far: each shows what a shape holds (a row's card, an arrow's card, a relationship type's definition), and zoomed out the shape shows none of it.
- **The bar is about no shape's content.** It hangs under the selection's bounds and acts on the selection; a skeleton draws the bounds as well as a full shape does. Refusing it there would make `/` do nothing below 35%.
- **The core knows no particular card** (`Cards.swift:7`, "The core knows nothing of what is in it"). A card saying what it is about is data on `CanvasCard`, as `adoptsPress` is; the core keeps no list of kinds of card.
- **Why not a view of the bar's own over the canvas** (`registrar.hostOverlay`, as Jump To's palette is, `.claude/rules/jump-to.md`): the card already hangs under a world rect and goes over it where there's no room below, follows the camera and the view's size, stays inside `unobscuredViewport`, gives its view's responder the keyboard and the canvas it back, closes on a press elsewhere, another board, an undo or editing, and is a popover to VoiceOver with a label (`.claude/rules/editor.md`, Cards). A view of the bar's own would write all of that again. This flag is the one thing in the way.

## Tactics

1. **`Sources/Canvas/Editor/Cards.swift`**: `CanvasCard` gains

   ```swift
   /// Not about what a shape draws (the command bar, which acts on the selection): it shows and stays
   /// at any zoom. False: refused, and closed `.skeleton`, while its shape is drawn as a skeleton (with
   /// no shape, while the board is).
   public let showsZoomedOut: Bool
   ```

   an `init` parameter defaulting to false, after `adoptsPress`. `showCard` still refuses one about a shape that isn't on the board, and asks neither skeleton question of such a card (`:97` to `:101`), and `cardFollowsCamera` doesn't close it `.skeleton` (`:165`); every other closing (`.pressedElsewhere`, `.editing`, `.board`, `.undo`, `.shapeGone`, `.leftView`) is as it is.
2. `CardView` and `layoutCard` change nothing: a card is sized in view points already, the same at every zoom.

### `Package.swift`

Nothing.

### Tests: CanvasTests `CardTests`

With CanvasTesting's `CardProbe` and `probeCard`, `skeletonZoom` set above the zoom so the board is drawn as skeletons:

- A card with `showsZoomedOut`, about no shape and about one drawn as a skeleton, shows; without it, refused (as now).
- Shown at 100%, it stays as the camera zooms out across the level (no `.skeleton` in the `ClosingLog`), and one without the flag closes `.skeleton` (as now).
- It still closes `.pressedElsewhere`, `.board`, `.undo` and `.leftView` zoomed out.

### Docs (same commit)

- `.claude/rules/editor.md`, Cards: the flag, and that every other card is refused and closed among skeletons.
- `docs/plugin-system.md`, Cards (`:13781`): the flag in the init's list, with the bar as its reason.

## Verification

- `./build.sh audit` passes.
- `./test.sh` (`build/debug/CanvasTests/CanvasTests` to iterate): `CardTests` green, every other card's tests unchanged (TypesTests' `arrowCardTests` "a card refused among skeletons" among them).

## Risks and open questions

- **A card that sets it but shows content** would show it at a zoom where its shape doesn't. Its doc says what it's for; no shipped card but the bar sets it.

## Not in this commit

- The bar itself ([04](04-the-command-bar.md)).
