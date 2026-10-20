import Canvas
import Foundation
import Queries

/// `:grouped-with(S)`, in Queries: the shapes in a group with a shape S matches, the outermost group
/// that counts on its board (`BoardGroups`), so what a click on either selects with it, on every
/// board of the file, never S's shape itself. `:grouped-with(*)` is every shape in a group. A relation
/// answered from the file (`reads: .file`): each board's groups are read from its shapes' paths once
/// a query, off the main actor, the first time the query asks.
public struct GroupQueriesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "group-queries" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.queryRelation(Word.groupedWith.rawValue, "it is in a group with a shape S matches: a click on either selects both",
                                example: #":grouped-with("API")"#, reads: .file, transitive: false,
                                prepare: { GroupMates(file: $0.fact(GroupedFile.self).file) },
                                seeds: { $0.grouped },
                                related: { id, mates in mates.mates(of: id) })
    }

    /// The word it adds.
    enum Word: String {
        case groupedWith = "grouped-with"
    }
}

/// The file as a query takes it up, for the groups its shapes' paths make: the records alone.
struct GroupedFile: QueryFileFact {
    let file: CanvasFile

    static func current(in editor: CanvasEditor) -> GroupedFile { GroupedFile(file: editor.withoutObservingDocument { editor.file }) }
}

/// Each board's groups, read once, off the main actor, the first time a query asks: the shapes in a
/// group, and each one's outermost group's shapes.
final class GroupMates: @unchecked Sendable {
    private let file: CanvasFile
    private let lock = NSLock()
    private var read: (grouped: Set<ShapeID>, outermost: [ShapeID: [ShapeID]])?

    init(file: CanvasFile) { self.file = file }

    /// Every shape in a group that counts.
    var grouped: Set<ShapeID> { groups.grouped }

    /// The shapes in `id`'s outermost group but it.
    func mates(of id: ShapeID) -> [ShapeID] { groups.outermost[id]?.filter { $0 != id } ?? [] }

    private var groups: (grouped: Set<ShapeID>, outermost: [ShapeID: [ShapeID]]) {
        lock.withLock {
            if let read { return read }
            var grouped = Set<ShapeID>(), outermost: [ShapeID: [ShapeID]] = [:]
            for board in file.everyBoard {
                let groups = BoardGroups(file[board].shapes.compactMap { record in record[GroupsProperty.self].map { (id: record.id, path: $0) } })
                for (id, path) in groups.paths {
                    grouped.insert(id)
                    if let first = path.first { outermost[id] = groups.shapes[first] }
                }
            }
            read = (grouped, outermost)
            return (grouped, outermost)
        }
    }
}
