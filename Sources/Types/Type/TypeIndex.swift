import Adornments
import Canvas
import Colors
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

/// What a commit changed in the file's types, told to `TypeIndex.onChange`: each set is the ids of the
/// shapes that changed in that way, in the same commit.
public struct TypeChange: Sendable {
    /// Types that came, went, or whose schema text, name or own list changed (a change of the mark alone
    /// is `marks`' only).
    public let types: Set<ShapeID>
    /// Shapes that came or went as a relationship type: held the mark with a schema, or stopped.
    public let marks: Set<ShapeID>
    /// Shapes that came or went as a type at all. `types` holds a type for every schema keystroke: this is
    /// how a note that becomes a type is told from one.
    public let membership: Set<ShapeID>
    /// Types whose own `is` list changed.
    public let lineage: Set<ShapeID>
    /// Every shape whose `is` list changed (a type, a note, an arrow), and removed shapes that held one.
    public let lists: Set<ShapeID>
    /// The whole file was read afresh (put in place): nothing above is a
    /// complete account of what moved, and every reader reads everything again.
    public let everything: Bool

    public init(types: Set<ShapeID> = [], marks: Set<ShapeID> = [], membership: Set<ShapeID> = [], lineage: Set<ShapeID> = [],
                lists: Set<ShapeID> = [], everything: Bool = false) {
        self.types = types
        self.marks = marks
        self.membership = membership
        self.lineage = lineage
        self.lists = lists
        self.everything = everything
    }

    /// Whether anything in it moved.
    public var isEmpty: Bool { !everything && types.isEmpty && marks.isEmpty && membership.isEmpty && lineage.isEmpty && lists.isEmpty }
}

/// The file's types, on every board: each shape that holds a schema (`TypeSchemaProperty`), its
/// name (its title, Titles') and a revision that moves whenever its schema or its name changes, so
/// what depends on a type (a `$ref`'s completion, a type's highlights, an instance's chips) can tell
/// it changed without reading it. And what is what, as Topology has it (the `is-a` edges as drawn, the
/// literal view: on the boards the app can show): the types each shape is (`is`, `links(of:)`, kept as
/// a value in the graph, in the order of its list, for a query and a run to read), the instances of each
/// type (`instances(of:)`, asked of Topology) and the chain a shape's types make (`lineage(of:)`). Read
/// when the file opens, a scan of every board, then kept by each commit's `ChangeSet` alone (what it
/// added, removed and changed, on the board shown and elsewhere, the kind checked first), a file put in
/// place read again. Nothing per frame, and nothing for a shape that only moved. It never transacts; it tells Adornments to make the chips of the instances of a type again
/// when the type is renamed, recolored (its shape's `color`, or the file's colors it names), deleted or
/// comes back, and Colors when what a type's shapes are drawn in may have changed with no commit to them
/// (`color(inheritedBy:)`: a type recolored, come or gone, or a chain changed while a type holds a color).
@MainActor
@Observable
public final class TypeIndex {
    private struct Entry {
        var schema: String
        var name: String?
        var revision: Int
        /// The color the type's shape holds (not what it is drawn in: `look(of:)`), nil for none. Not
        /// part of its revision, which is what its schema and its name say.
        var color: ShapeColor?
        /// Whether the type's shapes fill their fields from their words, as its shape holds it (its `$autofill`),
        /// nil for no say. Not part of its revision either.
        var autofill: Bool?
        var isRelationship: Bool
    }

    /// What a pass over some records found changed: the sets of a `TypeChange`, and the shapes whose name,
    /// or whether they are a type, changed (their readers hear it, and their instances' chips are made
    /// again).
    private struct Heard {
        var types: Set<ShapeID> = [], marks: Set<ShapeID> = [], membership: Set<ShapeID> = []
        var lineage: Set<ShapeID> = [], lists: Set<ShapeID> = [], renamed: Set<ShapeID> = []
        /// Types whose shape holds another color now (or that came or went holding one): what their notes take.
        var recolored: Set<ShapeID> = []
        /// A type's shape says otherwise of whether its shapes fill their fields (or came or went saying it).
        var autofills = false

        var change: TypeChange { TypeChange(types: types, marks: marks, membership: membership, lineage: lineage, lists: lists) }
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
    @ObservationIgnored private var observers: [@MainActor (TypeChange) -> Void] = []
    /// Each shape's types, in the order of its list (only the shapes that are some: Topology's `is-a`
    /// edges as drawn, so on a board the app can show), and the names of the types: kept as a value, so a
    /// query takes it up in O(1), the relationships' fit reads it off the main actor and a run lays its
    /// own lists over a copy.
    @ObservationIgnored private var kept = TypeGraph()
    /// The last title each type was known by in this session.
    @ObservationIgnored private var lastNames: [ShapeID: String] = [:]
    /// How often a type's name, or whether it's there, has changed: what a reader of `name(of:)`
    /// observes.
    @ObservationIgnored private var nameVersions: [ShapeID: Int] = [:]
    /// Moves whenever what a list of types resolves to may: a type comes, goes, its schema's text
    /// changes, or its own `is` list does. Not for a rename, and not for another shape's list.
    @ObservationIgnored internal private(set) var chainRevision = 0
    /// The types whose shape holds a color: what a shape of a type may take (`color(inheritedBy:)`).
    @ObservationIgnored private var colored: Set<ShapeID> = []
    /// Moves whenever a type's shape holds another color, or a type comes or goes holding one.
    @ObservationIgnored private var colorRevision = 0
    /// The colors the types of each list's chain hold, in its order, as of `heldAt` (`chainRevision`,
    /// `colorRevision`): asked for every shape of a type in view, each frame.
    @ObservationIgnored private var heldByList: [[TypeLink]: [ShapeColor]] = [:]
    @ObservationIgnored private var heldAt = (-1, -1)

    #if DEBUG
    /// How many records it has read (debug builds only): a shape that only moved is read by none, a
    /// drag reads nothing.
    @ObservationIgnored public private(set) var recordsRead = 0
    /// How many times the colors a list's chain holds were worked out (debug builds only): once a list,
    /// until a chain or a type's color changes, however many shapes hold it.
    @ObservationIgnored public private(set) var chainColorsRead = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        let registry = editor.registry
        kinds = Set(registry.kinds.filter { registry.canBeType($0) })
        typeableKinds = Set(registry.kinds.filter { registry.isTypeable($0) })
        standInKinds = registry.standIns.kinds
        readEveryShape(in: editor)
        // The book of colors (what a type's own color is drawn in), made first: asked for as the index is.
        editor.colors?.onChange { [weak self] in self?.fileColorsDidChange() }
    }

    /// Whether the shape is a type: it holds a schema.
    public func isType(_ id: ShapeID) -> Bool { entries[id] != nil }

    /// Every type of the file, in no order.
    public var types: Set<ShapeID> { Set(entries.keys) }

    /// Whether any shape lists a type that is gone (deleted, or no longer a type): its fields are unknown,
    /// and the values of the shapes that list it are kept. O(the entries listed).
    public var listsAGoneType: Bool { kept.links.values.contains { $0.contains { entries[$0.shape] == nil } } }

    /// Moves whenever a type comes, goes, or changes its schema, name or own types: what the lines `--ask` is
    /// told (`FileFields.text(for:)`) are made from.
    var stamp: Int { chainRevision &+ revisions }

    /// A type's name, its title; nil for an untitled type and a shape that isn't one.
    public func name(of id: ShapeID) -> String? { entries[id]?.name }

    /// How a type's color is drawn: the color its shape holds where the file has it, else one of
    /// eight by its id (`TypeColors`). Asked of any id, a type that is gone included; it keeps nothing
    /// per type, so it is the color of the commit last heard.
    public func look(of id: ShapeID) -> TypeLook {
        TypeColors.look(of: id, own: entries[id]?.color, book: editor?.colors)
    }

    /// The color a shape takes from its types where it holds none of its own (`TypeColorsPlugin`): the
    /// first the file has of the colors its chain's types' shapes hold, in the order its fields resolve
    /// (`lineage(of:)`: a type before what it builds on, the one added later first). Only a color a type's
    /// shape holds counts; the one its id says is its pill's and chips', never its notes'. Nil for a type
    /// (its color is its own), a shape of no type, and one whose chain holds no color. Asked as each
    /// such shape is drawn, so what a list's chain holds is worked out once and kept until a chain or a
    /// type's color changes; while no type holds a color, it is a set's emptiness.
    public func color(inheritedBy id: ShapeID) -> ShapeColor? {
        guard !colored.isEmpty, entries[id] == nil, let links = kept.links[id] else { return nil }
        let held = heldColors(of: links, shape: id)
        guard !held.isEmpty, let book = editor?.colors else { return nil }
        return held.first(where: book.has)
    }

    /// Whether a shape of a type fills its fields from its words (`FieldFill`): its own say (`autofill`), else what
    /// its types say (`autofillInherited(by:)`). For a type, what its shapes do unless they say otherwise.
    public func autofills(_ record: AnyShapeRecord) -> Bool {
        record[AutofillProperty.self] ?? autofillInherited(by: record.id)
    }

    /// What a shape's types say of filling, with no say of its own: the first that a type of its chain holds, in
    /// the order its fields resolve (`lineage(of:)`: a type before what it builds on, the one added later first),
    /// as a color is taken (`color(inheritedBy:)`); true where none says. For a type, what the types it builds on
    /// say. Asked as a fill is about to start and by the panel, never per frame.
    public func autofillInherited(by id: ShapeID) -> Bool {
        for type in kept.lineage(of: id) {
            if let held = entries[type]?.autofill { return held }
        }
        return true
    }

    /// The colors the types of `id`'s chain hold, in its order: worked out once for each list, as the
    /// field book resolves one, and again after a chain or a type's color changes.
    private func heldColors(of links: [TypeLink], shape id: ShapeID) -> [ShapeColor] {
        if heldAt != (chainRevision, colorRevision) {
            heldByList.removeAll(keepingCapacity: true)
            heldAt = (chainRevision, colorRevision)
        }
        if let known = heldByList[links] { return known }
        #if DEBUG
        chainColorsRead += 1
        #endif
        let found = kept.lineage(of: id).compactMap { entries[$0]?.color }
        heldByList[links] = found
        return found
    }

    /// A type's schema text, as the shape holds it; nil for a shape that isn't one.
    func schemaText(of id: ShapeID) -> String? { entries[id]?.schema }

    /// A number that changes whenever the type's schema or name does; nil for a shape that isn't one.
    public func revision(of id: ShapeID) -> Int? { entries[id]?.revision }

    /// Calls `body` after each commit that changed types: the ids of those that came, went, or whose schema,
    /// name or own types changed (`types`; every type there was and is, when a file is put in place), that
    /// came or went as a relationship type (`marks`) or as a type at all (`membership`), whose own list
    /// changed (`lineage`), and every shape whose list did (`lists`). A commit that changed none of them tells
    /// nobody.
    public func onChange(_ body: @escaping @MainActor (TypeChange) -> Void) {
        observers.append(body)
    }

    /// Whether the shape is a type that is no relationship type: one a field may hold the fields of in
    /// place (a `$ref`). A relationship type's fields belong to its arrows.
    public func canBeEmbedded(_ id: ShapeID) -> Bool {
        guard let entry = entries[id] else { return false }
        return !entry.isRelationship
    }

    // MARK: What is what

    /// The types the shape is, in the order of its list (a later one wins); none for a shape that
    /// isn't an instance of any, or isn't there. An entry may name a shape that's gone.
    public func links(of id: ShapeID) -> [TypeLink] { kept.links[id] ?? [] }

    /// The shapes whose list names the shape: its instances, directly (not those of the types that
    /// are instances of it). Topology's: the carriers of the `is-a` edges into it, as drawn.
    public func instances(of type: ShapeID) -> Set<ShapeID> {
        var found: Set<ShapeID> = []
        if let topology = editor?.topology { Self.forEachInstance(of: type, in: topology) { found.insert($0) } }
        return found
    }

    /// Calls `body` with each of `instances(of:)` as `topology` (the editor's) has them, making no set: what
    /// a walk over the instances of instances reads them by, Topology looked up once for the walk.
    public static func forEachInstance(of type: ShapeID, in topology: TopologyIndex, _ body: (ShapeID) -> Void) {
        topology.forEachEdge(of: type, .incoming, types: isA, view: .literal) { body($0.carrier) }
    }

    /// The shapes that are of the type however far, never a type: its instances and those of every type built
    /// on it (myCar is a Car through Toyota; Toyota, built on Car, is none), as `:is-a` finds them. Walked
    /// through Topology (`affected(by:)`).
    public func allInstances(of type: ShapeID) -> Set<ShapeID> {
        affected(by: [type]).filter { entries[$0] == nil }
    }

    /// Whether any shape's list names the shape: `instances(of:)` not empty, making nothing.
    public func hasInstances(_ type: ShapeID) -> Bool {
        editor?.topology?.hasEdges(of: type, .incoming, types: Self.isA, view: .literal) ?? false
    }

    /// What a shape is, among the edges Topology keeps: made once, as a filter is made of a list.
    private static let isA = EdgeTypeFilter.only(IsAEdge.id)

    /// The shapes a shape is, in the order its types are read in: a type before every type it builds
    /// on; where a shape's list leaves a choice, the later added first (C3; where it has no order, a
    /// depth-first walk, a type still before what it builds on); each once, never the shape itself,
    /// so the chain of a shape that is its own ancestor stops where it comes back. A name that is
    /// gone is in it, ending its branch; check `isType` before reading one.
    public func lineage(of id: ShapeID) -> [ShapeID] { kept.lineage(of: id) }

    /// The types a shape is through the types its list names, as its chain reads them: what they build on,
    /// however far, in the chain's order, each with the first of its list's types it comes through (myCar
    /// is a Car through Toyota). Through types alone, as the chain goes: a name that is gone, or a shape that
    /// is no type now, ends its branch. What the Types tab lists under a shape's own.
    public func builtOn(of id: ShapeID) -> [(type: ShapeID, through: ShapeID)] {
        let own = (kept.links[id] ?? []).map(\.shape)
        let parents = { (shape: ShapeID) in self.entries[shape] == nil ? [] : self.kept.parents(of: shape) }
        let reach = own.filter { entries[$0] != nil }.map { (head: $0, reached: kept.chained([$0])) }
        return TypeOrder.linearized(TypeOrder.heads(of: own), excluding: id, parents: parents).compactMap { type in
            guard entries[type] != nil, !own.contains(type), let through = reach.first(where: { $0.reached.contains(type) })?.head else { return nil }
            return (type, through)
        }
    }

    /// The file's types as a value: every shape's types and the types' names, which a query reads
    /// (`:is-a`, a type's title where `is` is read). Copy on write: held by a query, a commit copies
    /// what it changes, once.
    public var graph: TypeGraph { kept }

    /// The shapes that read through these: every instance of them, and every instance of those, and
    /// so on, each once (the shapes themselves only where the chain comes back to them). What a
    /// change to a type changes: its instances, near and far.
    public func affected(by changed: Set<ShapeID>) -> Set<ShapeID> {
        guard let topology = editor?.topology else { return [] }
        var reached: Set<ShapeID> = [], level = changed
        while !level.isEmpty {
            var next: Set<ShapeID> = []
            for shape in level {
                Self.forEachInstance(of: shape, in: topology) { instance in if reached.insert(instance).inserted { next.insert(instance) } }
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

    @ObservationIgnored private var changesTold = 0
    /// A key path to observe.
    private var changeCount: Int { changesTold }

    /// Read in the body of a view that shows what types give a shape (the panel's Fields, a form): it
    /// draws again after a commit that changed a type (one that came, went, or whose schema, name or own
    /// types changed), which `chainRevision` alone does not tell a view.
    func observeChanges() { access(keyPath: \.changeCount) }

    @ObservationIgnored private var autofillsTold = 0
    private var autofillCount: Int { autofillsTold }

    /// Read in the body of a view that shows whether a shape fills its fields (the panel's box): it draws again
    /// after a commit in which a type's shape said otherwise of it (or came or went saying it), which moves no
    /// revision and tells `observeChanges` nothing.
    func observeAutofills() { access(keyPath: \.autofillCount) }

    // MARK: What may be what

    /// Whether `/is-a` may make `owner` an instance of `target`: `target` is a type (a shape of a kind
    /// that stands in for others, a pill, never is), not `owner` itself, not one `owner` is already,
    /// however far through types (`TypeGraph.chained`: a Toyota is a Car through Toyota, so Car is not
    /// offered it), and not one that is `owner` in turn, which would make a cycle (`reaches`). `replacing`
    /// are entries the pick takes the place of (an arrow's relationship type), so what they make `owner`
    /// is not counted. A few lookups for a shape that is no type and has none.
    public func admits(_ target: ShapeID, for owner: ShapeID, replacing: Set<ShapeID> = []) -> Bool {
        guard target != owner, mayBe(target, for: owner) else { return false }
        return admits(target, for: owner, already: already(owner, replacing: replacing))
    }

    /// What `owner` is already: each entry of its list, and what those a pick doesn't replace are built on, through types.
    private func already(_ owner: ShapeID, replacing: Set<ShapeID>) -> Set<ShapeID> {
        let own = (kept.links[owner] ?? []).map(\.shape)
        return kept.chained(own.filter { !replacing.contains($0) }).union(own)
    }

    private func admits(_ target: ShapeID, for owner: ShapeID, already: Set<ShapeID>) -> Bool {
        guard target != owner, !already.contains(target), mayBe(target, for: owner) else { return false }
        return !kept.reaches(owner, from: target)
    }

    /// The types `owner` may be (`admits`, with what a pick replaces), by name (case aside, the id the tie), an
    /// untitled one last: what `/is-a`'s list shows. O(types) a time it is asked, which is when a
    /// list opens.
    public func choices(for owner: ShapeID, replacing: Set<ShapeID> = []) -> [(type: ShapeID, name: String?)] {
        let already = already(owner, replacing: replacing)
        return Self.sorted(entries.keys.filter { admits($0, for: owner, already: already) }.map { ($0, entries[$0]?.name) })
    }

    /// The types a menu for `shapes` lists: every type some shape has or may be (`admits`, with what a pick replaces
    /// on that shape), in the order `choices(for:)` gives. O(types × shapes), once a menu opens.
    public func menuChoices(for shapes: [ShapeID], replacing: [ShapeID: Set<ShapeID>] = [:]) -> [(type: ShapeID, name: String?)] {
        let held = shapes.map { (shape: $0, already: already($0, replacing: replacing[$0] ?? [])) }
        return Self.sorted(entries.keys.filter { type in
            held.contains { admits(type, for: $0.shape, already: $0.already) || (kept.links[$0.shape] ?? []).contains(TypeLink(type)) }
        }.map { ($0, entries[$0]?.name) })
    }

    /// Orders types by name, case aside, an untitled one last, the
    /// id the tie. Each name is lowercased once and compared as plain text: Foundation's collation and
    /// folding cost several times what the rest of opening a list does.
    private static func sorted(_ types: [(ShapeID, String?)]) -> [(type: ShapeID, name: String?)] {
        let keyed = types.map { (type: $0.0, name: $0.1, key: $0.1?.lowercased(), id: $0.0.rawValue.uuidString) }
        return keyed.sorted { a, b in
            switch (a.key, b.key) {
            case (nil, nil): a.id < b.id
            case (nil, _): false
            case (_, nil): true
            case (let x?, let y?): x == y ? a.id < b.id : x < y
            }
        }.map { (type: $0.type, name: $0.name) }
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

    /// What the shape is now, if it's a type, and whether that differs from what's kept: kept, with its
    /// revision moved. `heard` gets the shape in what changed: `types` when it came, went or its schema or
    /// name did, `marks` when it came or went as a relationship type (a flip of the mark alone moves its
    /// revision and nothing else), `membership` when it came or went as a type, `renamed` when its name, its
    /// color, or whether it's a type, is what changed. A color alone (with its schema's `$color`, which says it
    /// too) is kept with no revision moved, and is heard in `renamed` alone.
    private func read(_ record: AnyShapeRecord, registry: Registry, heard: inout Heard) {
        #if DEBUG
        recordsRead += 1
        #endif
        guard let schema = record[TypeSchemaProperty.self] else {
            drop(record.id, heard: &heard)
            return
        }
        let name = registry.title(of: record), color = record.ownColor, autofill = record[AutofillProperty.self]
        let mark = record[RelationshipProperty.self] == true
        let kept = entries[record.id]
        // A type given another color has it written in its schema too (its `$color`): that alone is a color
        // change, which moves no revision (`TypeColorDirective`); so is a type told whether its shapes fill (its
        // `$autofill`), which nothing keeps but its entry.
        let sameSchema = kept.map { HeldDirectives.sameButHeld($0.schema, schema.text) } ?? false
        let same = sameSchema && kept?.name == name
        if var kept, same, kept.isRelationship == mark {
            guard kept.color != color || kept.schema != schema.text || kept.autofill != autofill else { return }
            let recolored = kept.color != color
            if kept.autofill != autofill { heard.autofills = true }
            kept.color = color
            kept.autofill = autofill
            kept.schema = schema.text
            entries[record.id] = kept
            if recolored {
                heard.renamed.insert(record.id)
                recolor(record.id, to: color, heard: &heard)
            }
            return
        }
        if kept == nil { heard.membership.insert(record.id) }
        if kept?.autofill != autofill { heard.autofills = true }
        if kept == nil || kept?.name != name || kept?.color != color { heard.renamed.insert(record.id) }
        if kept?.color != color { recolor(record.id, to: color, heard: &heard) }
        if let name { lastNames[record.id] = name }
        if !sameSchema { chainRevision &+= 1 }
        if (kept?.isRelationship ?? false) != mark { heard.marks.insert(record.id) }
        if !same { heard.types.insert(record.id) }
        revisions += 1
        put(record.id, Entry(schema: schema.text, name: name, revision: revisions, color: color, autofill: autofill, isRelationship: mark))
    }

    /// A record's list as the index reads a committed shape's: each type its `is` names once, the first, in
    /// order, as Topology's property rule emits the `is-a` edges (TypesTests hold the two to each other); none for
    /// a shape kept aside. For a record no index holds yet: what a run writes.
    public static func links(of record: AnyShapeRecord) -> [TypeLink] {
        guard !record.isOpaque, let list = record[IsAProperty.self] else { return [] }
        var seen: Set<ShapeID> = []
        return list.filter { seen.insert($0.shape).inserted }
    }

    /// The types a carrier's edges, as emitted, say it is, in their order.
    private static func links(from edges: [Edge]) -> [TypeLink] {
        edges.compactMap { $0.type == IsAEdge.id ? TypeLink($0.target) : nil }
    }

    /// What the shape's list is now, as Topology has it: its `is-a` edges as drawn, in the order of its
    /// list (none on a board the app can't show, or kept aside). True if that changed.
    @discardableResult
    private func readLinks(of id: ShapeID, in topology: TopologyIndex) -> Bool {
        #if DEBUG
        recordsRead += 1
        #endif
        let now = Self.links(from: topology.edges(carriedBy: id, view: .literal))
        guard now != kept.links[id] ?? [] else { return false }
        kept.links[id] = now.isEmpty ? nil : now
        return true
    }

    private func put(_ id: ShapeID, _ entry: Entry) {
        entries[id] = entry
        kept.names[id] = entry.name
        kept.types.insert(id)
        if entry.isRelationship { kept.relationshipTypes.insert(id) } else { kept.relationshipTypes.remove(id) }
    }

    /// The shape is no type now (gone, or its schema taken away): it left as a type, and as a relationship
    /// type if it was one.
    private func drop(_ id: ShapeID, heard: inout Heard) {
        kept.names[id] = nil
        guard let entry = entries.removeValue(forKey: id) else { return }
        kept.types.remove(id)
        kept.relationshipTypes.remove(id)
        chainRevision &+= 1
        heard.types.insert(id)
        heard.membership.insert(id)
        heard.renamed.insert(id)
        if entry.isRelationship { heard.marks.insert(id) }
        if entry.color != nil { recolor(id, to: nil, heard: &heard) }
        if entry.autofill != nil { heard.autofills = true }
    }

    /// The type's shape holds another color now, or none (it came or went holding one): what the shapes
    /// of it take is worked out again, and heard.
    private func recolor(_ id: ShapeID, to color: ShapeColor?, heard: inout Heard) {
        if color == nil { colored.remove(id) } else { colored.insert(id) }
        colorRevision &+= 1
        heard.recolored.insert(id)
    }

    /// A list changed: it is told in `lists`. A type's own list changing is told in `types` and `lineage`
    /// too, and moves the stamp: what its instances resolve to may have changed. An instance's list is in
    /// no chain, so it moves nothing else.
    private func readLinks(of id: ShapeID, in topology: TopologyIndex, heard: inout Heard) {
        guard readLinks(of: id, in: topology) else { return }
        heard.lists.insert(id)
        guard entries[id] != nil else { return }
        chainRevision &+= 1
        heard.types.insert(id)
        heard.lineage.insert(id)
    }

    /// A shape that's gone from the file holds no list.
    private func forgetLinks(of id: ShapeID, heard: inout Heard) {
        guard kept.links.removeValue(forKey: id) != nil else { return }
        heard.lists.insert(id)
    }

    private func readEveryShape(in editor: CanvasEditor) {
        let registry = editor.registry, file = editor.file, topology = editor.topology
        var heard = Heard()
        func read(_ shapes: [AnyShapeRecord]) {
            for record in shapes {
                if kinds.contains(record.kind) { self.read(record, registry: registry, heard: &heard) }
                if let topology, typeableKinds.contains(record.kind) { readLinks(of: record.id, in: topology) }
            }
        }
        // Every board the file has, shown or not: what is a type is read off its record, and what a note is
        // follows Topology (`readLinks`), which reads only the boards the app can show.
        for board in file.everyBoard { read(file[board].shapes) }
    }

    private func tell(_ change: TypeChange) {
        guard !change.isEmpty else { return }
        // What the views of a type's fields observe moves for a change to a type, never for a list alone.
        if !change.types.isEmpty || change.everything { withMutation(keyPath: \.changeCount) { changesTold &+= 1 } }
        for observer in observers { observer(change) }
    }

    /// A type's name, its color, or whether it's there, changed: the readers of its name hear it, and
    /// the chips of its instances are made again (its own pill is its shape's, which the commit that
    /// changed it names).
    private func told(renamed: Set<ShapeID>, in editor: CanvasEditor) {
        guard !renamed.isEmpty else { return }
        var chips: Set<ShapeID> = []
        let topology = editor.topology
        for type in renamed {
            withMutation(keyPath: \.[nameVersion: type]) { nameVersions[type, default: 0] += 1 }
            if let topology { Self.forEachInstance(of: type, in: topology) { chips.insert($0) } }
        }
        if !chips.isEmpty { editor.adornmentsDidChange(for: chips) }
    }

    /// The file's colors changed: a type that holds a color by name may be drawn in another now, or
    /// in its id's; one that holds a value, or none, is not.
    private func fileColorsDidChange() {
        guard let editor else { return }
        let named = Set(entries.filter { $0.value.color?.name != nil }.keys)
        guard !named.isEmpty else { return }
        // Their own pills too: no commit names them.
        editor.adornmentsDidChange(for: named)
        told(renamed: named, in: editor)
    }

    /// Everything read again, for a file put in place, which forgets what its types were called (they
    /// are another file's). Those told hear once the index has it (`editor.onceHeard`).
    private func readAfresh(in editor: CanvasEditor) {
        let before = Set(entries.keys), instances = Set(kept.links.keys)
        let marksBefore = kept.relationshipTypes, colorsBefore = !colored.isEmpty
        chainRevision &+= 1
        entries = [:]
        kept = TypeGraph()
        lastNames = [:]
        colored = []
        readEveryShape(in: editor)
        let recolors = colorsBefore || !colored.isEmpty
        let now = Set(entries.keys)
        let moved = before.union(now)
        let own = Set(kept.links.keys.filter { entries[$0] != nil }).union(instances.filter { before.contains($0) })
        let change = TypeChange(types: moved, marks: marksBefore.union(kept.relationshipTypes), membership: moved, lineage: own,
                                lists: instances.union(kept.links.keys), everything: true)
        let chips = instances.union(kept.links.keys)
        editor.onceHeard { [weak self, unowned editor] in
            guard let self else { return }
            tell(change)
            // Every chip may name another type.
            for type in moved { withMutation(keyPath: \.[nameVersion: type]) { nameVersions[type, default: 0] += 1 } }
            if !chips.isEmpty { editor.adornmentsDidChange(for: chips) }
            if recolors { editor.colors?.inheritedColorsDidChange() }
            toldAutofills()
        }
    }

    /// What a type says of its shapes' filling changed: the views that show it draw again.
    private func toldAutofills() {
        withMutation(keyPath: \.autofillCount) { autofillsTold &+= 1 }
    }
}

extension TypeIndex: EditorService {
    /// Follows the commit; those told (`onChange`, the readers of a name, the chips of its instances) hear
    /// once the index has it (`editor.onceHeard`), so they may read it then.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        if changes.replacedDocument { return readAfresh(in: editor) }
        let registry = editor.registry, file = editor.file, topology = editor.topology
        var heard = Heard()
        for id in changes.removed where file.record(id) == nil {
            drop(id, heard: &heard)
            forgetLinks(of: id, heard: &heard)
        }
        // A shape that only moved (a drag) has the schema, the name and the types it had. Its list is
        // Topology's, which has heard the commit (looking it up has it hear first).
        func hear(_ id: ShapeID) {
            guard let record = editor.document[id] else { return }
            if kinds.contains(record.kind) { read(record, registry: registry, heard: &heard) }
            if let topology, typeableKinds.contains(record.kind) { readLinks(of: id, in: topology, heard: &heard) }
        }
        // (Two passes, not a set of both: a drag of everything makes none, and a set of its ids costs more than it saves.)
        for id in changes.added where !changes.moved.contains(id) { hear(id) }
        for id in changes.changed where !changes.moved.contains(id) { hear(id) }
        // A board taken or brought back holds thousands of shapes, and few are types: the kind first.
        for id in changes.elsewhere {
            guard let record = file.record(id) else {
                drop(id, heard: &heard)
                forgetLinks(of: id, heard: &heard)
                continue
            }
            if kinds.contains(record.kind) { read(record, registry: registry, heard: &heard) }
            if let topology, typeableKinds.contains(record.kind) { readLinks(of: id, in: topology, heard: &heard) }
        }
        let change = heard.change, renamed = heard.renamed
        // What a type's shapes are drawn in follows its color and its chain, which no commit to them says: a type
        // recolored that has shapes of it (or went), or a chain changed while a type holds a color.
        let recolors = heard.recolored.contains { entries[$0] == nil || hasInstances($0) }
            || (!colored.isEmpty && !(heard.lineage.isEmpty && heard.membership.isEmpty))
        let autofills = heard.autofills
        guard !change.isEmpty || !renamed.isEmpty || autofills else { return }
        editor.onceHeard { [weak self, unowned editor] in
            self?.tell(change)
            self?.told(renamed: renamed, in: editor)
            if recolors { editor.colors?.inheritedColorsDidChange() }
            if autofills { self?.toldAutofills() }
        }
    }

    /// A whole file put in place with the board switch is read again; a switch alone changes no type
    /// (the index is the file's, whatever board is shown).
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        guard change.isFileReplaced else { return }
        readAfresh(in: editor)
    }
}

extension CanvasEditor {
    /// The file's types (`TypeIndex`); nil without TypesPlugin.
    public var types: TypeIndex? { service(TypeIndex.self) }
}
