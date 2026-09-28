import Canvas
import DetailPanel

/// Mentions, as a plugin: text that mentions shapes, as pills. A kind opts into being mentioned
/// (`x.mentionable(...)`), saying how its shapes are called; text holds mentions when its type is
/// `ScopedMentionText<Scope>` (`MentionText` for any mentionable shape), whose scope says what it
/// may mention. It's stored as one string with inline `@[name](shape:ID)` tokens, and each
/// mention is a name, not a binding (`ShapeNaming`): deleting the shape it names writes nothing,
/// its pills show the name they hold, dashed, and putting the shape back brings them back to life.
/// `MentionState` keeps who mentions whom, each target's look, and what the `@` picker offers. The
/// core never learns what a mention is.
extension PluginID {
    public static let mentions: PluginID = "mentions"
}

/// Mentions' service, its faces on the canvas (a click on a pill edits its shape from the pill, if
/// its kind is `Editable`, and a double-click on a live one goes to what it names wherever no text
/// view took the click before: a read-only shape's, a kind's with no editing view), an overlay
/// that draws nothing but tells the canvas's memo of mention text where each frame ends, and Show
/// What Mentions in the context menu. A list with a mentionable kind, or one that draws mention
/// text, needs it (`ownerNotInstalled` otherwise), and installs it after Titles, whose names it
/// shows, and after the table of contents, whose rows it names. Its faces are Selection's, so the
/// list needs `SelectionPlugin()` too (and so `KeyboardPlugin()`), and its menu item ContextMenus'
/// (`ContextMenusPlugin()`).
public struct MentionsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .mentions }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { MentionState(editor: $0) }
        registrar.overlay(MentionFrames())
        registerMentionFaces(into: &registrar)
        registerMentionMenus(into: &registrar)
    }
}
