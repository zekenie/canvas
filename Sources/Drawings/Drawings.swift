import Canvas
import Draw

// Drawings: what a program drew on a board's file, kept so it can see a person's changes and take another pass. For each
// drawing, by its name, the file keeps the board its top went on and every shape it made, by id, with the program's key for
// it and what it last wrote on it, its properties and its place (Draw's `DrawingRecord`). Nothing is kept on the shapes, so a
// copy of a drawn shape isn't part of the drawing. `canvas apply` (a document by key) and `canvas draw --drawing NAME` write a
// drawing's record in the step that draws it, through Draw's point (`DrawRecords`), which this plugin fills; the query words
// that read it are `DrawingQueriesPlugin`'s.

extension PluginID {
    public static let drawings: PluginID = "drawings"
}

/// Every drawing a file keeps, by name.
public struct DrawingRecords: Codable, Equatable, Sendable {
    public var drawings: [String: DrawingRecord]

    public init(drawings: [String: DrawingRecord] = [:]) {
        self.drawings = drawings
    }
}

/// The file's drawings (`drawings`): none until a program draws one.
public enum DrawingsProperty: FileProperty {
    public static let key: PropertyKey = "drawings"
    public static var defaultValue: DrawingRecords { DrawingRecords() }
}

/// Keeps drawings: the file value, and Draw's point that `apply` and `draw --drawing` read and write it through.
public struct DrawingsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .drawings }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(file: DrawingsProperty.self)
        registrar.drawRecords(
            read: { name, file in file[DrawingsProperty.self].drawings[name] },
            write: { name, record, transaction in
                var all = transaction.fileValue(DrawingsProperty.self)
                all.drawings[name] = record
                transaction.setFileValue(DrawingsProperty.self, to: all)
            },
            names: { file in file[DrawingsProperty.self].drawings.keys.sorted() })
    }
}
