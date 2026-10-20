import Canvas
import Validation

/// The warning a shape carries while it names a color the file lacks (`Color “brand” isn’t in
/// this file.`), about its `color`: a plugin value of its own, so a list without Validation leaves
/// it out. A hex value and a built-in name never warn. The rule reads the shape's own color and the
/// book, and a commit names the shapes it changes, so a commit costs what it changes; a commit to the
/// file's colors changes no shape's record, so the rule says it affects the shapes holding a name
/// when the names change (`ColorWarnings`).
public struct ColorValidationPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "color-validation" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ColorWarnings(editor: $0) }
        registrar.forShapes(holding: ColorProperty.self) { colorable in
            colorable.validate(ignoringMoves: true, affected: { changes, editor in
                editor.service(ColorWarnings.self)?.affected(by: changes) ?? []
            }) { shape, context in
                guard case .named(let name)? = shape.ownColor, let book = context.service(ColorBook.self),
                      !book.has(.named(name)) else { return [] }
                return [.warning("Color “\(name)” isn’t in this file.", field: ColorProperty.key.rawValue)]
            }
        }
    }
}

/// Names the shapes that hold a color's name when a commit changes the file's names, which no commit
/// to those shapes says: the rule's `affected`, asked once every service has the commit. It keeps
/// nothing of the shapes: it looks through the file when a name comes or goes, which is seldom. A
/// color given another value changes no warning, so a drag in the color panel over one of the file's
/// colors looks through nothing.
@MainActor
final class ColorWarnings {
    private unowned let editor: CanvasEditor
    /// The file's names (`ShapeColor.key(of:)`) as they were when last looked at.
    private var names: Set<String>
    /// What it answered for the commit it was last asked about, by the commit's revision: asked again (a rule a
    /// kind), it answers the same.
    private var answered: (revision: Int, holders: Set<ShapeID>)?

    init(editor: CanvasEditor) {
        self.editor = editor
        names = Self.names(of: editor.colors)
    }

    private static func names(of book: ColorBook?) -> Set<String> {
        Set(book?.fileColors.map { ShapeColor.key(of: $0.name) } ?? [])
    }

    /// The shapes holding a name, every board's, when the commit changed which names the file has; none otherwise.
    func affected(by changes: ChangeSet) -> Set<ShapeID> {
        guard changes.fileValues.contains(FileColorsProperty.key) else { return [] }
        if let answered, answered.revision == editor.revision { return answered.holders }
        let holders = holders(after: changes)
        answered = (editor.revision, holders)
        return holders
    }

    private func holders(after changes: ChangeSet) -> Set<ShapeID> {
        let now = Self.names(of: editor.colors)
        guard now != names else { return [] }
        names = now
        let file = editor.withoutObservingDocument { editor.file }
        var holders: Set<ShapeID> = []
        for board in file.everyBoard {
            for record in file[board].shapes where !record.isOpaque {
                if case .named? = record.ownColor { holders.insert(record.id) }
            }
        }
        return holders
    }
}

extension ColorWarnings: EditorService {
    /// A file put in place has its own names: what a commit after it changes is told from those.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        if change.isFileReplaced { names = Self.names(of: editor.colors) }
    }
}
