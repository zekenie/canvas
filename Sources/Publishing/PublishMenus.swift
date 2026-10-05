import Canvas
import ContextMenus
import SlashCommands

/// Make Public and Make Private in the context menu, and `/public` and `/private` in a shape's text.
///
/// The menu has one item for the shapes it's for, as Lock's: Make Public while any shape that can be
/// public isn't, which makes the rest public, else Make Private. An item is dimmed when it could do
/// nothing: every shape it would change is read-only (the core refuses a locked shape, and shakes
/// it), and, for Make Private, when every public shape is held by something that stands for it. On a
/// mix, the shapes nothing stands for go private in one step, and the held ones shake.
@MainActor
func registerPublishMenus(into registrar: inout PluginRegistrar) {
    registrar.contextMenuForCanvas {
        MenuItem(PublicStyle.makePublic, in: PublishMenuGroup.self,
                 when: { !$0.toMakePublic.isEmpty },
                 isEnabled: { subject in subject.toMakePublic.contains { !subject.editor.isReadOnly($0) } }) { ids, editor in
            editor.makePublic(ids.filter { id in editor.document[id].map { editor.registry.holdsPublic($0.kind) && $0[PublicProperty.self] != true } ?? false })
        }
        MenuItem(PublicStyle.makePrivate, in: PublishMenuGroup.self,
                 when: { $0.toMakePublic.isEmpty && !$0.toMakePrivate.isEmpty },
                 isEnabled: { subject in
                     let publishing = subject.editor.publishing
                     return subject.toMakePrivate.contains { !subject.editor.isReadOnly($0) && publishing?.isHeld($0) != true }
                 }) { ids, editor in
            editor.makePrivate(ids.filter { id in editor.document[id].map { editor.registry.holdsPublic($0.kind) && $0[PublicProperty.self] == true } ?? false })
        }
    }
    // `/public` while the shape is private, `/private` while it's public, typed on a line of its own
    // in a shape's text, as `/lock` is. A read-only shape's text can't be edited, so neither is ever
    // offered there. `/private` on a shape something stands for is refused as the chip is: nothing
    // is written, the shape shakes.
    registrar.slashCommandsForEveryShape(where: { $0.holds(PublicProperty.self) }) {
        SlashCommand("public", when: { $0[PublicProperty.self] != true }, step: PublicStyle.makePublic) { id, _, editor in editor.makePublic([id]) }
        SlashCommand("private", when: { $0[PublicProperty.self] == true }, step: PublicStyle.makePrivate) { id, _, editor in editor.makePrivate([id]) }
    }
}

extension MenuSubject {
    /// The menu's shapes that can be public and aren't: what Make Public would change.
    fileprivate var toMakePublic: [ShapeID] { shapes.filter { holds($0) && editor.document[$0]?[PublicProperty.self] != true } }

    /// The menu's shapes that are public and can be made private.
    fileprivate var toMakePrivate: [ShapeID] { shapes.filter { holds($0) && editor.document[$0]?[PublicProperty.self] == true } }

    private func holds(_ id: ShapeID) -> Bool { editor.document[id].map { editor.registry.holdsPublic($0.kind) } ?? false }
}
