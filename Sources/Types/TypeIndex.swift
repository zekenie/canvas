import Canvas
import Foundation
import Mentions
import Titles

/// The file's types, on every board: each shape that holds a schema (`TypeSchemaProperty`), its
/// name (its title, Titles') and a revision that moves whenever its schema or its name changes, so
/// what depends on a type (a `$ref`'s completion, a type's highlights, later its instances) can tell
/// it changed without reading it. Read when the file opens, a scan of every board, then kept by
/// each commit's `ChangeSet` alone (what it added, removed and changed, on the board shown and
/// elsewhere, the kind checked first); a file put in place is read again. Nothing per frame.
@MainActor
public final class TypeIndex {
    private struct Entry {
        var schema: String
        var name: String?
        var revision: Int
    }

    weak var editor: CanvasEditor?
    private var entries: [ShapeID: Entry] = [:]
    private var revisions = 0
    /// The kinds that can be types: every other shape is passed over at once.
    private let kinds: Set<ShapeKind>
    private var observers: [@MainActor (Set<ShapeID>) -> Void] = []

    init(editor: CanvasEditor) {
        self.editor = editor
        let registry = editor.registry
        kinds = Set(registry.kinds.filter { registry.canBeType($0) })
        readEveryType(in: editor)
    }

    /// Whether the shape is a type: it holds a schema.
    public func isType(_ id: ShapeID) -> Bool { entries[id] != nil }

    /// Every type of the file, in no order.
    public var types: Set<ShapeID> { Set(entries.keys) }

    /// A type's name, its title; nil for an untitled type and a shape that isn't one.
    public func name(of id: ShapeID) -> String? { entries[id]?.name }

    /// A number that changes whenever the type's schema or name does; nil for a shape that isn't one.
    public func revision(of id: ShapeID) -> Int? { entries[id]?.revision }

    /// Calls `body` after each commit that changed types, with the ids of those that came, went, or
    /// whose schema or name changed (every type there was and is, when a file is put in place).
    public func onChange(_ body: @escaping @MainActor (Set<ShapeID>) -> Void) {
        observers.append(body)
    }

    /// The types a `$ref` in the schema of `id` can point to, as its JSON's completions offer them:
    /// every other titled type of the file, by its name (what its mentions show), its fields counted,
    /// in the order of their names.
    public func referenceTargets(from id: ShapeID) -> [JSONCompletionOffer] {
        var found: [(name: String, type: ShapeID, detail: String)] = []
        for (type, entry) in entries where type != id {
            guard let name = entry.name else { continue }
            let shown = SchemaReadings.reading(of: entry.schema, for: type).shown
            found.append((name, type, TypePanelText.subtitle(shown) ?? ""))
        }
        found.sort { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.type.description < b.type.description : order == .orderedAscending
        }
        return found.map { TypeCompletions.type($0.type, named: $0.name, detail: $0.detail) }
    }

    // MARK: Keeping it

    /// What the shape is now, if it's a type, and whether that differs from what's kept: kept, with
    /// its revision moved, and true.
    private func read(_ record: AnyShapeRecord, registry: Registry) -> Bool {
        guard let schema = record[TypeSchemaProperty.self] else { return entries.removeValue(forKey: record.id) != nil }
        let name = registry.title(of: record)
        if let kept = entries[record.id], kept.schema == schema.text, kept.name == name { return false }
        revisions += 1
        entries[record.id] = Entry(schema: schema.text, name: name, revision: revisions)
        return true
    }

    private func readEveryType(in editor: CanvasEditor) {
        let registry = editor.registry, file = editor.file
        for record in file.root.shapes where kinds.contains(record.kind) { _ = read(record, registry: registry) }
        for board in file.children.values {
            for record in board.shapes where kinds.contains(record.kind) { _ = read(record, registry: registry) }
        }
    }

    private func tell(_ ids: Set<ShapeID>) {
        guard !ids.isEmpty else { return }
        for observer in observers { observer(ids) }
    }

    private func readAfresh(in editor: CanvasEditor) {
        let before = Set(entries.keys)
        entries = [:]
        readEveryType(in: editor)
        tell(before.union(entries.keys))
    }
}

extension TypeIndex: EditorService {
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        if changes.replacedDocument {
            readAfresh(in: editor)
            return
        }
        let registry = editor.registry, file = editor.file
        var changed: Set<ShapeID> = []
        for id in changes.removed where entries[id] != nil && file.record(id) == nil {
            entries[id] = nil
            changed.insert(id)
        }
        // A shape that only moved (a drag) has the schema and the name it had.
        for id in changes.added.union(changes.changed) where !changes.moved.contains(id) {
            guard let record = editor.document[id], kinds.contains(record.kind) else { continue }
            if read(record, registry: registry) { changed.insert(id) }
        }
        // A board taken or brought back holds thousands of shapes, and few are types: the kind first.
        for id in changes.elsewhere {
            guard let record = file.record(id) else {
                if entries.removeValue(forKey: id) != nil { changed.insert(id) }
                continue
            }
            guard kinds.contains(record.kind) else { continue }
            if read(record, registry: registry) { changed.insert(id) }
        }
        tell(changed)
    }

    /// A whole file put in place with the board switch is read again.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        guard change.isFileReplaced else { return }
        readAfresh(in: editor)
    }
}

extension CanvasEditor {
    /// The file's types (`TypeIndex`); nil without TypesPlugin.
    public var types: TypeIndex? { service(TypeIndex.self) }
}
