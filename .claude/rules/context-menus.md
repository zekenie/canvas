---
paths:
  - "Sources/ContextMenus/**"
  - "Tests/ContextMenusTests/**"
  - "Tests/CanvasTesting/Menus.swift"
  - "Examples/**"
---

# Context menus

Context menus: a shape's items and groups, the canvas's items, and what a right-click or a Control-click does.

Related: [selection](selection.md), [clipboard](clipboard.md), [locking](locking.md), [mentions](mentions.md), [boards](boards.md), [transform](transform.md), [slash commands](slash-commands.md) ([every topic](../../CLAUDE.md#map)).

In the guide, `docs/plugin-system.md`: [Context menus](../../docs/plugin-system.md#context-menus).

## Architecture

- Context menus (ContextMenus, a surface) follow the same pattern: `x.contextMenu { MenuItem("…", in: SomeGroup.self, when: { … }) { $0.field = … } }`, `registrar.contextMenu(P.self)` for another plugin's kind, `x.contextMenu(of: P.self) { … }` over an added property's value (on `PluginRegistrar`, every shape that has it), `contextMenuForEveryShape(where:)` (`where` picks kinds by their definition, so by capability; Reordering's Arrange submenu leaves out `PaintOrderAnchored` kinds). A group is a type (`MenuGroup`) in the tabs' order bands, with separators between groups; a horizontal's opt-in sugar calls `contextMenu` too, so opting in brings its items (Boards' Open). `when` leaves an item out (prefer it to `isEnabled`, which dims); nothing left, and the right-click does nothing. Items that aren't one shape's (Cut, Copy, Paste; Show What Mentions, since whether a shape is mentioned is what Mentions' state knows, not the shape; Turn into …, which a transform's target brings, since what a shape can turn into is what the registry knows: Transform's `TransformMenuGroup`, order 60, between Mentions' 50 and the clipboard's 100, [transform](transform.md)) are the canvas's: `registrar.contextMenuForCanvas { MenuItem("…", when: { $0.editor… }) { ids, editor in … } }`, over the menu's `MenuSubject` (its shapes, `point`, where it was asked for, in world units, which the `edit` form, handed the subject, reads, and the editor), asked once per menu, in every menu after the shapes' own, and alone on empty canvas; `when` asks the subject, never `canPerform`, since the menu's shapes become the selection only once it's made. ContextMenus has two of its own, Selection's commands, in `SelectionMenuGroup` (order 400, last, after Lock): Delete in every shape's menu, running `.delete` on them (a locked one shakes, as with the key), and Select All on empty canvas while the board has shapes, running `.selectAll`; so with Selection installed only an empty board with nothing to paste has no menu. The menu is for the selection: a right-click on an unselected shape selects it (only if it has a menu), and with several shapes an item shows when every one shows it (same group and id). The core only lends `registrar.menuForSecondaryClick`, which ContextMenus claims; `CanvasView.menu(for:)` asks it. A Control-click with no menu reaches the tool as a press with `pointer.isControlClick`: the select tool ignores it, and every other tool takes it as a press with ⌃ held (the hand tool pans), so ContextMenus answers Control-clicks only in the select tool.

## Testing

- For context menus, `h.secondaryClick(at:)` returns the `NSMenu` (or nil); read it with `menu.outline` and run an item with `menu.choose("Status", "Done")`. Nothing goes on screen.
