import Canvas
import ContextMenus

/// Mentions' items in the canvas's context menu: after a kind's own items, as a feature's are.
public enum MentionsMenuGroup {}

extension MentionsMenuGroup: MenuGroup {
    public static var order: Int { 50 }
}

/// Show What Mentions, in the context menu: an item for the canvas, since whether a shape is
/// mentioned is what Mentions' state knows, not the shape. Shown when another shape, on any board,
/// mentions one of the shapes the menu is for; it goes to what mentions them (`showWhatMentions`:
/// those on the board shown, if any are, else another board's), one step back.
@MainActor
func registerMentionMenus(into registrar: inout PluginRegistrar) {
    registrar.contextMenuForCanvas {
        MenuItem(MentionStyle.showWhatMentions, in: MentionsMenuGroup.self, when: { subject in
            guard let mentions = subject.editor.mentions else { return false }
            return subject.shapes.contains(where: mentions.isMentioned)
        }) { ids, editor in
            editor.mentions?.showWhatMentions(ids)
        }
    }
}
