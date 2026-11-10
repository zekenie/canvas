import Canvas
import ContextMenus
import Selection

/// Mentions' items in the canvas's context menu: right after a kind's own items, as a feature's are.
public enum MentionsMenuGroup {}

extension MentionsMenuGroup: MenuGroup {
    public static var order: Order<Self> { .after(ShapeMenuGroup.self) }
}

/// Show What Mentions, in the context menu: an item for the canvas, since whether a shape is
/// mentioned is what Mentions' state knows, not the shape. Shown when another shape, on any board,
/// mentions one of the shapes the menu is for; it goes to what mentions them (`showWhatMentions`:
/// those on the board shown, if any are, else another board's), one step back. With rows of the one shape selected as
/// its items, it is about those rows, as the panel's Mentioned By is: what mentions another row of the shape isn't it.
@MainActor
func registerMentionMenus(into registrar: inout PluginRegistrar) {
    registrar.contextMenuForCanvas {
        MenuItem(MentionStyle.showWhatMentions, in: MentionsMenuGroup.self, when: { subject in
            guard let mentions = subject.editor.mentions else { return false }
            return rowsOrShapes(subject.shapes, in: subject.editor).contains(where: mentions.isMentioned)
        }) { ids, editor in
            editor.mentions?.showWhatMentions(rowsOrShapes(ids, in: editor))
        }
    }
}

/// What a menu for `ids` is about: the rows selected as items of the one shape, else the shapes.
@MainActor
private func rowsOrShapes(_ ids: [ShapeID], in editor: CanvasEditor) -> [PartAddress] {
    if ids.count == 1, let items = editor.selectedItems, items.shape == ids[0] {
        let rows = items.ids.compactMap { ($0.base as? PartID).map { PartAddress(ids[0], part: $0) } }
        if rows.count == items.ids.count, !rows.isEmpty { return rows }
    }
    return ids.map { PartAddress($0) }
}
