import AppKit
import Canvas
import SlashCommands
import TextEditing

extension PluginID {
    public static let mentionSlashBar: PluginID = "mention-slash-bar"
}

/// Mentions' text as the command bar's field (`SlashBarFields`), so what's typed there can name a shape:
/// `/move-to @Roadmap` on the shapes selected moves them into it, as one block. The field is a
/// `MentionTextView` of one line and no owner (no shape owns the bar's text, and nothing writes it to
/// the board), set up as the bar's own field is (`SlashBarField.setUp`), in the bar's text on a neutral
/// surface, its pills tinted; it hosts slash commands for the selection (`hostSlashCommands(for:)`), a pill
/// a shape given, and its `@` picker lists for the shapes selected, nearest their middle first, each left
/// out, on a command's line only what the command takes for all of them. A plugin value of its own, after
/// the bar, whose point it fills, and Mentions, whose view it makes: a list with Mentions needs no bar.
public struct MentionSlashBarPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .mentionSlashBar }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.slashBarField(namesShapes: true) { editor, target, events in
            guard let mentions = editor.mentions else { return nil }
            let view = MentionTextView<AnyMentionable>(frame: .zero, text: "", style: MentionStyle.barText, owner: nil, mentions: mentions)
            view.isOneLine = true
            view.allowsUndo = true
            view.usesRuler = false
            view.usesFontPanel = false
            SlashBarField.setUp(view)
            guard let typing = view.hostSlashCommands(for: target) else { return nil }
            typing.willRun = events.willRun
            typing.willAnswer = events.willAnswer
            typing.didEdit = events.edited
            view.onExit = events.escape
            view.onLeave = events.left
            view.onEmptied = events.emptied
            return SlashBarField(view: view, typing: typing)
        }
    }
}

extension MentionStyle {
    /// Mention text in the command bar's field: the bar's font, in the label's color, on a neutral
    /// surface, so its pills are tinted as the panel's are.
    static let barText = MentionTextStyle(font: SlashBarField.font, color: .labelColor, surface: .neutral)
}
