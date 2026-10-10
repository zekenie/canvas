import Adornments
import Canvas
import Foundation
import Mentions
import Titles
import Topology

/// What a type is called where a shape's types are listed (`TypeIndex.name(of:)`).
public enum TypeLinkName: Equatable, Sendable {
    /// The type is there: its title, nil for a type with none.
    case live(String?)
    /// The type is gone (deleted, or no longer a type): the last title it was known by in this
    /// session, if any. Undoing the delete brings it back.
    case missing(lastKnown: String?)
}

/// The file's types, on every board: each shape that holds a schema (`TypeSchemaProperty`), its
/// name (its title, Titles') and a revision that moves whenever its schema or its name changes, so
/// what depends on a type (a `$ref`'s completion, a type's highlights, an instance's chips) can tell
/// it changed without reading it. And what is what: the types each shape is (`is`, `links(of:)`),
/// the instances of each type (`instances(of:)`) and the chain a shape's types make
/// (`lineage(of:)`). Read when the file opens, a scan of every board, then kept by each commit's
/// `ChangeSet` alone (what it added, removed and changed, on the board shown and elsewhere, the kind
/// checked first), a commit heard out of turn and a file put in place read again. Nothing per frame,
/// and nothing for a shape that only moved. It never transacts; it tells Adornments to make the
/// chips of the instances of a type again when the type is renamed, deleted or comes back.
@MainActor
@Observable
public final class TypeIndex {
    private struct Entry {
        var schema: String
        var name: String?
        var revision: Int
    }

    @ObservationIgnored weak var editor: CanvasEditor?
    @ObservationIgnored private var entries: [ShapeID: Entry] = [:]
    @ObservationIgnored private var revisions = 0
    /// The kinds that can be types: every other shape is passed over at once.
    @ObservationIgnored private let kinds: Set<ShapeKind>
    /// The kinds that can be instances of types.
    @ObservationIgnored private let typeableKinds: Set<ShapeKind>
    /// The kinds that stand in for other shapes (pills): never a type, whatever they stand for.
    @ObservationIgnored private let standInKinds: Set<ShapeKind>
    @ObservationIgnored private var observers: [@MainActor (Set<ShapeID>) -> Void] = []
    /// Each shape's types, in the order of its list (only the shapes that are some), and the names of
    /// the types: kept as a value, so a query takes it up in O(1).
    @ObservationIgnored private var kept = TypeGraph()
    /// The shapes whose list names each shape.
    @ObservationIgnored private var instancesByType: [ShapeID: Set<ShapeID>] = [:]
    /// The last title each type was known by in this session.
    @ObservationIgnored private var lastNames: [ShapeID: String] = [:]
    /// How often a type's name, or whether it's there, has changed: what a reader of `name(of:)`
    /// observes.
    @ObservationIgnored private var nameVersions: [ShapeID: Int] = [:]
    /// The revision of the editor it's up to date with.
    @ObservationIgnored private var heardRevision: Int

    #if DEBUG
    /// How many records it has read (debug builds only): a shape that only moved is read by none, a
    /// drag reads nothing.
    @ObservationIgnored public private(set) var recordsRead = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        let registry = editor.registry
        kinds = Set(registry.kinds.filter { registry.canBeType($0) })
        typeableKinds = Set(registry.kinds.filter { registry.isTypeable($0) })
        standInKinds = registry.standIns.kinds
        heardRevision = editor.revision
        readEveryShape(in: editor)
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

    // MARK: What is what

    /// The types the shape is, in the order of its list (a later one wins); none for a shape that
    /// isn't an instance of any, or isn't there. An entry may name a shape that's gone.
    public func links(of id: ShapeID) -> [TypeLink] { kept.links[id] ?? [] }

    /// The shapes whose list names the shape: its instances, directly (not those of the types that
    /// are instances of it).
    public func instances(of type: ShapeID) -> Set<ShapeID> { instancesByType[type] ?? [] }

    /// The shapes a shape is, in the order its types are read in: a type before every type it builds
    /// on; where a shape's list leaves a choice, the later added first (C3; where it has no order, a
    /// depth-first walk, a type still before what it builds on); each once, never the shape itself,
    /// so the chain of a shape that is its own ancestor stops where it comes back. A name that is
    /// gone is in it, ending its branch; check `isType` before reading one.
    public func lineage(of id: ShapeID) -> [ShapeID] { kept.lineage(of: id) }

    /// The file's types as a value: every shape's types and the types' names, which a query reads
    /// (`:is-a`, a type's title where `is` is read). Copy on write: held by a query, a commit copies
    /// what it changes, once.
    public var graph: TypeGraph { kept }

    /// The shapes that read through these: every instance of them, and every instance of those, and
    /// so on, each once (the shapes themselves only where the chain comes back to them). What a
    /// change to a type changes: its instances, near and far.
    public func affected(by changed: Set<ShapeID>) -> Set<ShapeID> {
        var reached: Set<ShapeID> = [], level = changed
        while !level.isEmpty {
            var next: Set<ShapeID> = []
            for shape in level {
                for instance in instancesByType[shape] ?? [] where reached.insert(instance).inserted { next.insert(instance) }
            }
            level = next
        }
        return reached
    }

    /// What a type is called where it's listed: its title while it's a type, else it's missing, with
    /// the last title it was known by in this session. Observed per type, so a view of a list of
    /// types draws again when one is renamed, deleted or brought back.
    public func name(of link: TypeLink) -> TypeLinkName {
        access(keyPath: \.[nameVersion: link.shape])
        if let entry = entries[link.shape] { return .live(entry.name) }
        return .missing(lastKnown: lastNames[link.shape])
    }

    private subscript(nameVersion id: ShapeID) -> Int { nameVersions[id] ?? 0 }

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

    // MARK: What may be what

    /// Whether `/is-a` may make `owner` an instance of `target`: `target` is a type (a shape of a kind
    /// that stands in for others, a pill, never is), not `owner` itself, not one `owner` is already,
    /// and not one that is `owner` in turn, which would make a cycle (`reaches`). A shape on any
    /// board of the file, asked of every shape the `@` picker ranks, so it costs a few lookups.
    public func admits(_ target: ShapeID, for owner: ShapeID) -> Bool {
        guard target != owner, mayBe(target, for: owner), !(kept.links[owner] ?? []).contains(TypeLink(target)) else { return false }
        return !kept.reaches(owner, from: target)
    }

    /// What a shape may be, by what the target is: a type. The one place that says so; the custom
    /// shapes of a later slice join here, as what a shape of their kind may be besides.
    private func mayBe(_ target: ShapeID, for owner: ShapeID) -> Bool {
        guard entries[target] != nil, let record = editor?.shape(inFile: target), !record.isOpaque else { return false }
        return !standInKinds.contains(record.kind)
    }

    /// Whether a script (draw) may name the record in `is`: it is a type (it holds a schema), and no
    /// pill. A pure function of the record and the registry, which draw's names have and services
    /// they don't; the one place that says so for words, as `mayBe` is for `/is-a`. The custom
    /// shapes of a later slice join here.
    ///
    /// `writing` is the keys of the properties a script writes on a shape it draws in the same run, so
    /// a type and its instances can be drawn together: a shape the script gives a schema is a type.
    public static func canBeNamed(_ record: AnyShapeRecord, registry: Registry, writing: Set<String> = []) -> Bool {
        guard !record.isOpaque, !registry.standIns.kinds.contains(record.kind) else { return false }
        return record[TypeSchemaProperty.self] != nil || (writing.contains(TypeSchemaProperty.key.rawValue) && registry.canBeType(record.kind))
    }

    // MARK: Keeping it

    /// What the shape is now, if it's a type, and whether that differs from what's kept: kept, with
    /// its revision moved, and true. `renamed` gets the shape when its name, or whether it's a type,
    /// is what changed.
    private func read(_ record: AnyShapeRecord, registry: Registry, renamed: inout Set<ShapeID>) -> Bool {
        #if DEBUG
        recordsRead += 1
        #endif
        guard let schema = record[TypeSchemaProperty.self] else {
            guard drop(record.id) else { return false }
            renamed.insert(record.id)
            return true
        }
        let name = registry.title(of: record)
        let kept = entries[record.id]
        if let kept, kept.schema == schema.text, kept.name == name { return false }
        if kept == nil || kept?.name != name { renamed.insert(record.id) }
        if let name { lastNames[record.id] = name }
        revisions += 1
        put(record.id, Entry(schema: schema.text, name: name, revision: revisions))
        return true
    }

    /// What the shape's list is now, filed under the types it names. True if that changed.
    @discardableResult
    private func readLinks(_ record: AnyShapeRecord) -> Bool {
        #if DEBUG
        recordsRead += 1
        #endif
        let now = record[IsAProperty.self] ?? []
        let before = kept.links[record.id] ?? []
        guard now != before else { return false }
        for link in before { instancesByType[link.shape]?.remove(record.id) }
        for link in before where instancesByType[link.shape]?.isEmpty == true { instancesByType[link.shape] = nil }
        kept.links[record.id] = now.isEmpty ? nil : now
        for link in now { instancesByType[link.shape, default: []].insert(record.id) }
        return true
    }

    private func put(_ id: ShapeID, _ entry: Entry) {
        entries[id] = entry
        kept.names[id] = entry.name
    }

    private func drop(_ id: ShapeID) -> Bool {
        kept.names[id] = nil
        return entries.removeValue(forKey: id) != nil
    }

    /// A shape that's gone from the file holds no list.
    private func forgetLinks(of id: ShapeID) {
        guard let before = kept.links.removeValue(forKey: id) else { return }
        for link in before {
            instancesByType[link.shape]?.remove(id)
            if instancesByType[link.shape]?.isEmpty == true { instancesByType[link.shape] = nil }
        }
    }

    private func readEveryShape(in editor: CanvasEditor) {
        let registry = editor.registry, file = editor.file
        var renamed: Set<ShapeID> = []
        func read(_ shapes: [AnyShapeRecord]) {
            for record in shapes {
                if kinds.contains(record.kind) { _ = self.read(record, registry: registry, renamed: &renamed) }
                if typeableKinds.contains(record.kind) { readLinks(record) }
            }
        }
        read(file.root.shapes)
        for board in file.children.values { read(board.shapes) }
    }

    private func tell(_ ids: Set<ShapeID>) {
        guard !ids.isEmpty else { return }
        for observer in observers { observer(ids) }
    }

    /// A type's name, or whether it's there, changed: the readers of its name hear it, and the
    /// chips of its instances are made again.
    private func told(renamed: Set<ShapeID>, in editor: CanvasEditor) {
        guard !renamed.isEmpty else { return }
        var chips: Set<ShapeID> = []
        for type in renamed {
            withMutation(keyPath: \.[nameVersion: type]) { nameVersions[type, default: 0] += 1 }
            chips.formUnion(instancesByType[type] ?? [])
        }
        if !chips.isEmpty { editor.adornmentsDidChange(for: chips) }
    }

    /// Everything read again. A file put in place forgets what its types were called (they are
    /// another file's); a commit heard out of turn is the same file, so a type it deleted is still
    /// known by the title it had.
    private func readAfresh(in editor: CanvasEditor, sameFile: Bool) {
        let before = Set(entries.keys), instances = Set(kept.links.keys)
        entries = [:]
        kept = TypeGraph()
        instancesByType = [:]
        if !sameFile { lastNames = [:] }
        readEveryShape(in: editor)
        let now = Set(entries.keys)
        tell(before.union(now))
        // Every chip may name another type.
        let moved = before.union(now)
        for type in moved { withMutation(keyPath: \.[nameVersion: type]) { nameVersions[type, default: 0] += 1 } }
        let chips = instances.union(kept.links.keys)
        if !chips.isEmpty { editor.adornmentsDidChange(for: chips) }
    }
}

extension TypeIndex: EditorService {
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        // Up to date already: a service committed while hearing an earlier commit, which this one
        // heard the later one of first.
        guard heardRevision != editor.revision else { return }
        let outOfTurn = heardRevision < editor.revision - 1
        heardRevision = editor.revision
        if changes.replacedDocument || outOfTurn {
            readAfresh(in: editor, sameFile: outOfTurn && !changes.replacedDocument)
            return
        }
        let registry = editor.registry, file = editor.file
        var changed: Set<ShapeID> = [], renamed: Set<ShapeID> = []
        for id in changes.removed where file.record(id) == nil {
            if drop(id) {
                changed.insert(id)
                renamed.insert(id)
            }
            forgetLinks(of: id)
        }
        // A shape that only moved (a drag) has the schema, the name and the types it had.
        func hear(_ id: ShapeID) {
            guard let record = editor.document[id] else { return }
            if kinds.contains(record.kind), read(record, registry: registry, renamed: &renamed) { changed.insert(id) }
            if typeableKinds.contains(record.kind) { readLinks(record) }
        }
        // (Two passes, not a set of both: a drag of everything makes none, and a set of its ids costs more than it saves.)
        for id in changes.added where !changes.moved.contains(id) { hear(id) }
        for id in changes.changed where !changes.moved.contains(id) { hear(id) }
        // A board taken or brought back holds thousands of shapes, and few are types: the kind first.
        for id in changes.elsewhere {
            guard let record = file.record(id) else {
                if drop(id) {
                    changed.insert(id)
                    renamed.insert(id)
                }
                forgetLinks(of: id)
                continue
            }
            if kinds.contains(record.kind), read(record, registry: registry, renamed: &renamed) { changed.insert(id) }
            if typeableKinds.contains(record.kind) { readLinks(record) }
        }
        tell(changed)
        told(renamed: renamed, in: editor)
    }

    /// A whole file put in place with the board switch is read again; a switch alone changes no type
    /// (the index is the file's, whatever board is shown).
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        heardRevision = editor.revision
        guard change.isFileReplaced else { return }
        readAfresh(in: editor, sameFile: false)
    }
}

extension CanvasEditor {
    /// The file's types (`TypeIndex`); nil without TypesPlugin.
    public var types: TypeIndex? { service(TypeIndex.self) }
}
