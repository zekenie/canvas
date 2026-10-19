import Canvas
import ContextMenus
import SlashCommands

extension CanvasCommand {
    /// Make Public: the shapes that can be public and aren't made public, while one isn't read-only.
    public static let makePublic: CanvasCommand = "makePublic"
    /// Make Private: the public shapes made private, while one isn't read-only and nothing stands for
    /// it; one something stands for stays public and shakes, and its panel shows what holds it.
    public static let makePrivate: CanvasCommand = "makePrivate"
}

/// Make Public and Make Private: two commands, which the context menu's items, `/public` and
/// `/private` in a shape's text and the public chip run.
///
/// The menu has one item for the shapes it's for, as Lock's: Make Public while any shape that can be
/// public isn't, which makes the rest public, else Make Private. An item is dimmed while its command
/// can do nothing: every shape it would change is read-only (the core refuses a locked shape, and
/// shakes it), and, for Make Private, every public shape is held by something that stands for it. On
/// a mix, the shapes nothing stands for go private in one step, and the held ones shake. `/private`,
/// as the chip, is a try: offered on a public shape, held or not, it shakes one that's held.
@MainActor
func registerPublishMenus(into registrar: inout PluginRegistrar) {
    registrar.command(.makePublic, title: PublicStyle.makePublic,
                      isEnabled: { subject in subject.toMakePublic.contains { !subject.editor.isReadOnly($0) } }) { subject in
        subject.editor.makePublic(subject.toMakePublic)
    }
    registrar.command(.makePrivate, title: PublicStyle.makePrivate,
                      isEnabled: { subject in
                          let publishing = subject.editor.publishing
                          return subject.toMakePrivate.contains { !subject.editor.isReadOnly($0) && publishing?.isHeld($0) != true }
                      }) { subject in
        subject.editor.makePrivate(subject.toMakePrivate)
    }
    // Items for any shapes, not a scope's: a menu over a mix, some of kinds that can't be public, has
    // them for the shapes that can be, which the commands pick out.
    registrar.contextMenuForCanvas {
        MenuItem(command: .makePublic, in: PublishMenuGroup.self, when: { !$0.toMakePublic.isEmpty }, dims: true)
        MenuItem(command: .makePrivate, in: PublishMenuGroup.self, when: { $0.toMakePublic.isEmpty && !$0.toMakePrivate.isEmpty }, dims: true)
    }
}

/// `/public` while the shape can be made public, `/private` while it's public, typed on a line of its
/// own in a shape's text, as `/lock` is, on the kinds that can be public (`scope`). A read-only shape's
/// text can't be edited, so neither is ever offered there. `/private` on a shape something stands for
/// is refused as the chip is: nothing is written, the shape shakes.
@MainActor
func registerPublishSlashCommands(into scope: inout ScopedRegistrar) {
    scope.slashCommands {
        SlashCommand("public", command: .makePublic)
        SlashCommand("private", command: .makePrivate, when: { $0[PublicProperty.self] == true }, tries: true)
    }
}

extension CommandSubject {
    /// The shapes that can be public and aren't: what Make Public would change.
    fileprivate var toMakePublic: [ShapeID] { shapes.filter { holds($0) && editor.document[$0]?[PublicProperty.self] != true } }

    /// The shapes that are public and can be made private.
    fileprivate var toMakePrivate: [ShapeID] { shapes.filter { holds($0) && editor.document[$0]?[PublicProperty.self] == true } }

    private func holds(_ id: ShapeID) -> Bool { editor.document[id].map { editor.registry.holdsPublic($0.kind) } ?? false }
}
