import Canvas
import Validation

/// The warning a shape carries while it names a color the file lacks (`Color “brand” isn’t in
/// this file.`), about its `color`: a plugin value of its own, so a list without Validation leaves
/// it out. A hex value and a built-in name never warn. The rule reads the shape's own color and the
/// book, and a commit names the shapes it changes, so a commit costs what it changes; the file's
/// colors change with no commit to a shape, so when they do the shapes holding a name are checked
/// again (`ColorWarnings`).
public struct ColorValidationPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "color-validation" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ColorWarnings(editor: $0) }
        registrar.validateEveryShape(ignoringMoves: true) { shape, context in
            guard case .named(let name)? = shape.ownColor, let book = context.service(ColorBook.self),
                  !book.has(.named(name)) else { return [] }
            return [.warning("Color “\(name)” isn’t in this file.", field: ColorProperty.key.rawValue)]
        }
    }
}

/// Has the shapes that hold a color's name checked again when the file's names change, which no
/// commit to those shapes says. It keeps nothing of the shapes: it looks through the file when a
/// name comes or goes, which is seldom. A color given another value changes no warning, so a drag
/// in the color panel over one of the file's colors looks through nothing.
@MainActor
final class ColorWarnings {
    private unowned let editor: CanvasEditor
    /// The file's names (`ShapeColor.key(of:)`) as they were when last looked at.
    private var names: Set<String>

    init(editor: CanvasEditor) {
        self.editor = editor
        names = Self.names(of: editor.colors)
        editor.colors?.onChange { [weak self] in self?.colorsDidChange() }
    }

    private static func names(of book: ColorBook?) -> Set<String> {
        Set(book?.fileColors.map { ShapeColor.key(of: $0.name) } ?? [])
    }

    private func colorsDidChange() {
        let now = Self.names(of: editor.colors)
        guard now != names else { return }
        names = now
        let file = editor.withoutObservingDocument { editor.file }
        var holders: Set<ShapeID> = []
        for board in [file.root] + file.children.values {
            for record in board.shapes where !record.isOpaque {
                if case .named? = record.ownColor { holders.insert(record.id) }
            }
        }
        editor.validation?.recheck(holders)
    }
}

extension ColorWarnings: EditorService {}
