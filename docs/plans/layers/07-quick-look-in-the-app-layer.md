# 07 · The Quick Look extension is part of the app; its packaging is a qualifier, not a layer

**Commit title:** The Quick Look extension is in the app layer, carried by the app (`// layer: app of InfiniteCanvas`), and the appex layer, whose one rule kept out a wire it already reached, is gone

**Depends on:** 01 (the charter). Independent of 02–06.

## Complaint

"Questioning if `Appex` layer belongs as its own layer at all."

## Justification

- **A layer has two jobs, and appex mixes them up.** It's an import rule (what a module may use) and, for executables, a build role (how build.sh packages it). appex's import rule barely differs from the app's, while its build role does all the work.
- **The import rule is close to empty.** `appex → foundation, ui` differs from `app → foundation, ui, wire` only by the wire, and the extension already reaches the wire twice:
  - through CanvasUI, which imports CanvasRPC for `CommandServer` (`Sources/CanvasUI/CommandServer.swift`);
  - through `+ shipped`, which links Automation and QueryCommands, both on CanvasRPC.

  So the rule forbids only a direct `import CanvasRPC` in three files that have no reason to write one.
- **The "no wire" rule has never been more than that.** When the layer was born (commit `1698396`), the app's rule was foundation, ui, composition and wire, and the extension's foundation, ui and composition: the difference was the wire even then. Composition is gone (`8c828bb`), and the difference is still only a direct import of the wire.
- **The build role is real, and keyed on the layer name:**
  - linked to start in `NSExtensionMain` (`build.sh:736`);
  - staged into two `.appex` bundles, with Info.plists, and signed with the sandbox entitlement (`:952-1023`);
  - checked to be the only such executable (`:961`);
  - built by `./build.sh` (`:620`) and kept in `tests` mode, which skips only the app (`:622`).

  The app and the extension already share everything else that makes them "the product": `+ shipped`, `@_spi(Product)`, naming no plugin, `VISIBLE` excluding the list's modules. Each of those checks names both layers: as `(app|appex)` (`:231, :471, :556`), as `(foundation|app|appex)` (`:553`), or in the `SHIPPING_LAYER` table (`:45`, checked at `:140`).
- **The charter (plan 01):** a layer answers one question about what a module may know. "Is it the product's executable?" is that question for both, and they answer it the same. *Which bundle it goes in* is a fact about packaging. It belongs beside the layer, not as a layer.
- **The grammar already exists.** A target line can qualify its layer with `of <Module>` (`// layer: test of QueryLexicon`, parsed at `build.sh:87`). `// layer: app of InfiniteCanvas` reads as what it is, an executable the app carries, with no new syntax.

## Tactics

1. **`Package.swift`:**
   - `CanvasQuickLook`'s line becomes `// layer: app of InfiniteCanvas`.
   - The header drops the appex row. The app row says: "the product's executables: the app, and what it carries (`of` the app: an extension macOS runs on its own, packaged into the app's bundle)".
2. **`build.sh`:**
   - `MAY_USE`, `EXECUTABLE_LAYER` and `SHIPPING_LAYER`: drop `appex`.
   - The `SUBJECT` check (`:257-264`) branches on the layer:
     - `test of M` stays as it is;
     - `app of A` requires A to be an `app` target with no `of` of its own, and does *not* require a dependency on it, since an executable can't depend on an executable.
   - Replace `(app|appex)` with `app` at `:231`, `:471` and `:556`, and `(foundation|app|appex)` with `(foundation|app)` at `:553`, where `@_spi(Product)` is allowed. One place each, mechanical. `SHIPPING_LAYER` drops appex in the step above.
   - The extension-specific tests use "app with a subject" in place of `== appex`:
     - the `NSExtensionMain` entry (`:736`);
     - the staging and signing (`:952-1023`);
     - the one-extension check (`:961`, reworded "the app carries one extension, the Quick Look one; it has N");
     - `app` mode's executable list (`:620`).
   - `tests` mode (`:622`) skips only the app itself (`app` with no subject). That keeps today's behavior, where test.sh still compiles the extension.
   - The die messages that say "the app or its extension" stay true.
3. **Sources:** none. The extension's three files import Canvas, CanvasUI and system frameworks, which the app's rule allows.
4. **Docs:**
   - `.claude/rules/build.md`:
     - "The module graph and the audit": the layer list, and "an appex is…" → "an executable the app carries (`app of InfiniteCanvas`)";
     - "Building": "both the appex layer's one executable" → "the executable the app carries".
   - `.claude/rules/quick-look.md`: where it names the appex layer.
   - `docs/plugin-system.md`: the module-graph table (drop the appex row, extend the app row) and the audit list ("the app, its Quick Look extension…" stays true).
   - `CLAUDE.md`: nothing names appex. Check with `grep -n appex CLAUDE.md`.

## Verification

- `./build.sh audit`. Then try a forbidden form and see it refused: `app of CanvasUI` (not an app), and `app of CanvasQuickLook` (an extension carrying an extension).
- `./build.sh` produces `Contents/PlugIns/QuickLookPreview.appex` and `QuickLookThumbnail.appex` byte-identical to the previous build. The signing copy is skipped when nothing changed, so a second build replacing nothing is the check.
- `./test.sh` still builds CanvasQuickLook.
- In the Finder: space on a `.canvasboard` previews the board.

## Risks and open questions

- **The no-wire rule is lost.** If keeping the extension off the wire matters (a sandboxed extension shouldn't open the server's socket), the real guard is that nothing in the extension starts a `CommandServer`. The import rule never enforced that, since CanvasUI carries it either way. If it should be enforced, it's a check on what the extension *calls*, not on what it imports.

## Not in this commit

- The cli layer: its rule ("knows only the wire") is a real, different import rule, so it stays a layer.
