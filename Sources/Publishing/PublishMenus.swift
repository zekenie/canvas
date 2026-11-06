import Canvas
import ContextMenus
import SlashCommands

extension CanvasCommand {
    /// Make Public: the private shapes made public, while one isn't read-only.
    public static let makePublic: CanvasCommand = "makePublic"
    /// Make Private: the public shapes made private, while one isn't read-only and nothing stands for
    /// it; one something stands for stays public and shakes, and its panel shows what holds it.
    public static let makePrivate: CanvasCommand = "makePrivate"
}

/// Make Public and Make Private: two commands, which the context menu's items, `/public` and
/// `/private` in a shape's text and the private chip run.
///
/// The menu has one item for the shapes it's for, as Lock's: Make Public while any of them is
/// private, which makes those public, else Make Private. An item is dimmed while its command
/// can do nothing: every shape it would change is read-only (the core refuses a locked shape, and
/// shakes it). Make Private stays enabled on a public shape something stands for, as the chip's click
/// and `/private` are: it changes nothing, shakes the shape, and the panel shows what holds it
/// (Connections), so the key explains itself. On a mix, the shapes nothing stands for go private in
/// one step, and the held ones shake.
@MainActor
func registerPublishMenus(into registrar: inout PluginRegistrar) {
    registrar.command(.makePublic, title: PublicStyle.makePublic,
                      isEnabled: { subject in subject.toMakePublic.contains { !subject.editor.isReadOnly($0) } }) { subject in
        subject.editor.makePublic(subject.toMakePublic)
    }
    registrar.command(.makePrivate, title: PublicStyle.makePrivate,
                      isEnabled: { subject in subject.toMakePrivate.contains { !subject.editor.isReadOnly($0) } }) { subject in
        subject.editor.makePrivate(subject.toMakePrivate)
    }
    // Items for any shapes, not a scope's: a menu over a mix, some of kinds that can't be public, has
    // them for the shapes that can be, which the commands pick out.
    registrar.contextMenuForCanvas {
        MenuItem(command: .makePublic, in: PublishMenuGroup.self, when: { !$0.toMakePublic.isEmpty }, dims: true)
        MenuItem(command: .makePrivate, in: PublishMenuGroup.self, when: { $0.toMakePublic.isEmpty && !$0.toMakePrivate.isEmpty }, dims: true)
    }
}

/// `/public` while the shape is private, `/private` while it's public, typed on a line of its
/// own in a shape's text, as `/lock` is, or for the shapes selected, on the kinds that can be private
/// (`scope`). Each reaches exactly the shapes it would change (`when`: `/public` the private ones,
/// `/private` the public ones), so a selection of a public and a private shape counts `1 of 2` for each.
/// A read-only shape's text can't be edited, so neither is ever offered there. `/private` on a shape
/// something stands for is refused as the chip is: nothing is written, the shape shakes, and the rest
/// of what it was given go private.
@MainActor
func registerPublishSlashCommands(into scope: inout ScopedRegistrar) {
    scope.slashCommands {
        SlashCommand("public", command: .makePublic, when: { $0[PrivateProperty.self] == true })
        SlashCommand("private", command: .makePrivate, when: { $0[PrivateProperty.self] != true && !$0.isOpaque }, tries: true)
    }
}

extension CommandSubject {
    /// The shapes that are private: what Make Public would change.
    fileprivate var toMakePublic: [ShapeID] { shapes.filter { holds($0) && editor.document[$0]?[PrivateProperty.self] == true } }

    /// The shapes that are public and can be made private (not one kept aside, which nothing stands for).
    fileprivate var toMakePrivate: [ShapeID] {
        shapes.filter { holds($0) && editor.document[$0].map { $0[PrivateProperty.self] != true && !$0.isOpaque } == true }
    }

    private func holds(_ id: ShapeID) -> Bool { editor.document[id].map { editor.registry.holdsPrivate($0.kind) } ?? false }
}
