import Adornments
import Canvas
import CanvasRPC
import Foundation
import Mentions
import Observation
import Titles
import Topology
import Validation

/// The types that refer to each other, by their JSON: a `$ref` to a type's URI, with or without a
/// fragment. Both ways, so an edit to a type reaches the types that refer to it and a type that is gone
/// still knows who waits for it.
struct TypeReferences {
    /// The types each type's text refers to.
    private(set) var targets: [ShapeID: Set<ShapeID>] = [:]
    /// The types whose text refers to each type, gone or not.
    private(set) var referrers: [ShapeID: Set<ShapeID>] = [:]

    /// What `type`'s text refers to now.
    mutating func set(_ type: ShapeID, refersTo new: Set<ShapeID>) {
        let before = targets[type] ?? []
        guard before != new else { return }
        for gone in before.subtracting(new) {
            referrers[gone]?.remove(type)
            if referrers[gone]?.isEmpty == true { referrers[gone] = nil }
        }
        for added in new.subtracting(before) { referrers[added, default: []].insert(type) }
        targets[type] = new.isEmpty ? nil : new
    }
}

/// What a run says of a shape it wrote (`FieldChecks.drawn`).
public struct DrawnFields: Sendable {
    public var check: FieldCheck
    public var unnamed: [UnnamedMember]
    public var typeNames: [String]

    public init(check: FieldCheck, unnamed: [UnnamedMember], typeNames: [String]) {
        self.check = check
        self.unnamed = unnamed
        self.typeNames = typeNames
    }
}

/// What the check says of a shape's values: for each shape that has types, the problems its values have
/// against its types' fields, kept until something it was made from changes. The check itself is
/// `FieldChecker`'s, pure over the field book; this keeps one checker for each distinct list of types,
/// the answer for each shape, `typing`, and which shapes a type's edit reaches.
///
/// An answer is never invalidated: it is trusted while the shape's own list and values are the ones it
/// was made from and its checker is current (`FieldBook.revision`), so a type edit, an undo and a file
/// put in place all need nothing done to the answers. Two compares that end at the storage's identity
/// and an integer: a frame of notes in view asks it for each at no cost.
@MainActor
@Observable
public final class FieldChecks {
    private struct Answer {
        var links: [TypeLink]
        var values: FieldValues?
        /// Nil when no type of the list is a type.
        var checker: FieldChecker?
        /// The book's revision a checker-less answer was made at.
        var stamp: Int
        /// `FieldChecks.names` when the answer holds a problem that names a type (a rule across fields).
        var nameStamp: Int?
        /// The validator's part and the relationship part together.
        var check: FieldCheck
        /// The validator's part alone.
        var base: FieldCheck
        /// What the arrow's ends say of its relationship types; nil for a kind that does not relate.
        var relation: RelationPart?
    }

    /// What an arrow's ends say, with what it was made from: the index's stamp for the arrow and its revision
    /// (any end, mark or lineage moved), and the rename count when the words name a type. Made again by the
    /// next ask when any of them has moved, the validator's part not asked.
    private struct RelationPart {
        var stamp = -1
        var revision = -1
        var names: Int?
        var problems: [FieldProblem] = []
    }

    @ObservationIgnored private weak var editor: CanvasEditor?
    /// The services it reads, found once: a frame asks for each note in view, and a lookup by type costs more than the rest of an ask.
    @ObservationIgnored private let book: FieldBook?
    @ObservationIgnored private let index: TypeIndex?
    @ObservationIgnored private let relationships: RelationshipIndex?
    @ObservationIgnored private var answers: [ShapeID: Answer] = [:]
    @ObservationIgnored private var checkers: [[ShapeID]: FieldChecker] = [:]
    @ObservationIgnored private var references: TypeReferences?
    @ObservationIgnored private var recent: (links: [TypeLink], revision: Int, checker: FieldChecker?)?
    @ObservationIgnored private var typingStorage: (shape: ShapeID, path: FieldPath)?
    @ObservationIgnored private var typingObservers: [@MainActor () -> Void] = []
    /// Moves when any type was renamed: an answer that names a type is made again.
    @ObservationIgnored private var names = 0
    /// The shapes whose answer names a type.
    @ObservationIgnored private var named: Set<ShapeID> = []
    @ObservationIgnored private var lastChain: Int
    /// What a run's check made for lists it read over the transaction (`check(of:reading:)`), by list: dropped
    /// by the commit that ends the run.
    @ObservationIgnored private var scratch: [[ShapeID]: [Scratch]] = [:]
    @ObservationIgnored private var scratchCount = 0
    /// The types a list reads, with those they refer to, by list: what must be unchanged for the kept answer to hold.
    @ObservationIgnored private var closures: (revision: Int, byList: [[ShapeID]: [ShapeID]]) = (-1, [:])
    /// The notes a sentence quotes by their label (`“foundation” is a Layer`), with the label as quoted and the
    /// arrows that quote it: nothing tells an arrow that its end was renamed, so a commit that names one of
    /// these compares its label now. Empty while no arrow of the file is a misfit.
    @ObservationIgnored private var quotes: [ShapeID: (label: String, arrows: Set<ShapeID>)] = [:]
    /// The notes each arrow quotes: what `quotes` lets go of when the arrow's part is made again.
    @ObservationIgnored private var quotedBy: [ShapeID: [ShapeID]] = [:]
    /// The arrows with no type that `looseEnd` calls a loose end: they keep no answer, so a recheck of everything
    /// names them by this.
    @ObservationIgnored private var looseEnds: Set<ShapeID> = []
    /// The kinds that say where their rows go: a note of one holds relationships in rows, and the rules of its rows are checked.
    @ObservationIgnored private let rowKinds: Set<ShapeKind>
    /// By row: the notes whose kept answer holds an Only one issue of it (an error), each with the name the issue says. A rename
    /// of a row is a change in the words of those issues and names no note (it leaves the partition equal), so a commit that
    /// changed rows checks the rows' names against these and makes again the notes of the rows that are called otherwise.
    @ObservationIgnored private var rowErrors: [RelationshipRowKey: [ShapeID: String]] = [:]
    /// The same for the notes whose Needed row is empty (what a note still needs, Validation's third level): a rename of the row
    /// only changes their issues' words, so those notes are not made again, only marked stale (`ValidationEngine.recheckWords`).
    @ObservationIgnored private var rowNeeded: [RelationshipRowKey: [ShapeID: String]] = [:]
    /// The rows each note holds in `rowErrors` and `rowNeeded`.
    @ObservationIgnored private var rowErrorKeys: [ShapeID: [RelationshipRowKey]] = [:]

    #if DEBUG
    /// How many checkers have been made, and how many values checked (debug builds only): tests hold
    /// them to one for each distinct list and one for each changed shape.
    @ObservationIgnored public private(set) var checkersMade = 0
    @ObservationIgnored public private(set) var checksMade = 0
    /// How many checkers a run made over a reading (`check(of:reading:)`).
    @ObservationIgnored public private(set) var scratchMade = 0
    /// How many times an arrow's relationship part was made (the validator's is `checksMade`).
    @ObservationIgnored public private(set) var relationPartsMade = 0
    #endif

    /// The most lists kept; past it all are dropped.
    private static let capacity = 1_024
    /// The most checkers a run keeps for types it changes.
    private static let scratchCapacity = 16

    /// `rowKinds` are the kinds that say where their rows go (`TypeRows`, which this part sits below): a note of one holds its
    /// relationships in rows, and the rules of its rows are checked.
    public init(editor: CanvasEditor, rowKinds: Set<ShapeKind> = []) {
        self.editor = editor
        book = editor.fieldBook
        index = editor.types
        relationships = editor.relationships
        self.rowKinds = rowKinds
        lastChain = editor.types?.chainRevision ?? 0
        editor.types?.onChange { [weak self] change in
            // Only a change to a type: a mark or a list alone changes nothing a chain resolves to.
            if !change.types.isEmpty { self?.typesChanged(change.types) }
        }
        // After the types': the ends are current when this hears, and an arrow it names is checked again.
        editor.relationships?.onChange { [weak self] change in self?.relationshipsChanged(change) }
    }

    // MARK: Answering

    /// The answer for a shape, with `typing` left out. Reading it from a view tracks `revision`.
    public func check(of record: AnyShapeRecord) -> FieldCheck {
        _ = revision
        let full = fullCheck(of: record)
        guard let typing = typingStorage, typing.shape == record.id, !full.problems.isEmpty else { return full }
        return full.leaving(out: typing.path)
    }

    /// The whole answer for a shape, `typing` ignored: for queries.
    public func fullCheck(of record: AnyShapeRecord) -> FieldCheck {
        // (An opaque shape holds nothing typed, so it has no `is` and is passed here.) The book's revision is the index's
        // stamp, read from the index at hand: the book finds it by a lookup of the service.
        guard let book, let index else { return .clean }
        guard let links = record[IsAProperty.self], !links.isEmpty, record[TypeSchemaProperty.self] == nil else { return looseEnd(of: record) }
        let revision = index.chainRevision
        let values = record[FieldValuesProperty.self]
        let id = record.id
        let old = answers[id]
        if let old, old.links == links, old.values == values {
            if let checker = old.checker {
                if checker.stamp == revision, old.nameStamp == nil || old.nameStamp == names {
                    return relationCurrent(old, id) ? old.check : relationRemade(old, of: record)
                }
            } else if old.stamp == revision {
                return relationCurrent(old, id) ? old.check : relationRemade(old, of: record)
            }
        }
        let checker = self.checker(for: links, revision: revision, book: book, index: index)
        let base: FieldCheck
        if let old, let checker, old.checker === checker, old.links == links, old.values == values, old.nameStamp == nil || old.nameStamp == names {
            base = old.base
        } else if let checker {
            if let values, !values.isEmpty {
                #if DEBUG
                checksMade += 1
                #endif
                base = checker.check(values)
            } else {
                base = checker.emptyCheck(names: names)
            }
        } else {
            base = .clean
        }
        let namesAType = base.problems.contains { $0.path.isRoot }
        var answer = Answer(links: links, values: values, checker: checker, stamp: revision, nameStamp: namesAType ? names : nil, check: base, base: base, relation: nil)
        if let editor, editor.registry.relates(record.kind) || rowKinds.contains(record.kind) {
            // The checker was made again (the type's text changed): the ends are as they were, if the index says so.
            let part: RelationPart
            if let old, old.links == links, let kept = old.relation, relationCurrent(old, id) { part = kept } else { part = relationPart(of: record, links: links) }
            answer.relation = part
            answer.check = base.merging(part.problems)
        }
        if namesAType || answer.relation?.names != nil { named.insert(id) } else if !named.isEmpty { named.remove(id) }
        answers[id] = answer
        return answer.check
    }

    // MARK: Relationships

    /// Whether an answer's relationship part is the one the index would make now. While no relationship type
    /// exists a kept part is current only if it is empty: unmarking or deleting the file's last one, and the
    /// undo of the first, clear and bring back what it said.
    private func relationCurrent(_ answer: Answer, _ id: ShapeID) -> Bool {
        guard let part = answer.relation else { return true }
        guard let relationships, relationships.isActive else { return part.problems.isEmpty }
        return part.revision == relationships.revision && part.stamp == relationships.stamp(of: id) && (part.names == nil || part.names == names)
    }

    /// The answer with its relationship part made again and the validator's kept.
    private func relationRemade(_ old: Answer, of record: AnyShapeRecord) -> FieldCheck {
        var answer = old
        let part = relationPart(of: record, links: old.links)
        answer.relation = part
        answer.check = old.base.merging(part.problems)
        if part.names != nil { named.insert(record.id) } else if old.nameStamp == nil { named.remove(record.id) }
        answers[record.id] = answer
        return answer.check
    }

    /// What an arrow's ends say of the relationship types in its list. Stamp and revision are read before the
    /// work, so a change during it is caught at the next compare.
    private func relationPart(of record: AnyShapeRecord, links: [TypeLink]) -> RelationPart {
        guard let relationships, let editor else { return RelationPart() }
        var part = RelationPart(stamp: relationships.stamp(of: record.id), revision: relationships.revision)
        forgetQuotes(of: record.id)
        forgetRowErrors(of: record.id)
        guard relationships.isActive else { return part }
        let graph = relationships.graph
        // A note says what its ruled rows lack or hold too many of; an arrow, what its ends are.
        if !editor.registry.relates(record.kind) {
            let rows = relationships.ruledRows(for: links.map(\.shape))
            guard !rows.isEmpty else { return part }
            #if DEBUG
            relationPartsMade += 1
            #endif
            part.problems = RelationChecks.note(rows: rows, count: { relationships.relations(of: record.id, in: $0).count }, graph: graph)
            if RelationChecks.namesATitle(part.problems) { part.names = self.names }
            for problem in part.problems where problem.kind == .wrong || problem.kind == .needed {
                guard case .row(let key) = problem.locus, let name = problem.place.first else { continue }
                if problem.kind == .wrong { rowErrors[key, default: [:]][record.id] = name } else { rowNeeded[key, default: [:]][record.id] = name }
                rowErrorKeys[record.id, default: []].append(key)
            }
            return part
        }
        guard links.contains(where: { graph.isRelationshipType($0.shape) }) else { return part }
        #if DEBUG
        relationPartsMade += 1
        #endif
        let verdict = RelationChecks.arrow(types: links.map(\.shape), ends: relationships.subjects(of: record.id), graph: graph, naming: naming(in: editor))
        part.problems = verdict.problems
        if !verdict.problems.isEmpty { part.names = self.names }
        if !verdict.quoted.isEmpty {
            quotedBy[record.id] = verdict.quoted
            for shape in verdict.quoted {
                var held = quotes[shape] ?? (label(of: shape, in: editor), [])
                held.arrows.insert(record.id)
                quotes[shape] = held
            }
        }
        return part
    }

    private func forgetRowErrors(of note: ShapeID) {
        guard !rowErrorKeys.isEmpty, let keys = rowErrorKeys.removeValue(forKey: note) else { return }
        for key in keys {
            rowErrors[key]?[note] = nil
            if rowErrors[key]?.isEmpty == true { rowErrors[key] = nil }
            rowNeeded[key]?[note] = nil
            if rowNeeded[key]?.isEmpty == true { rowNeeded[key] = nil }
        }
    }

    /// The notes whose Only one or Needed issue says a name its row is not called now.
    private func notesOfRenamedRows(_ relationships: RelationshipIndex) -> Set<ShapeID> {
        notesOfRenamedRows(rowErrors, relationships)
    }

    /// The notes whose Needed issue says a name its row is not called now: their words only are stale, so Validation is
    /// told so and checks nothing (a keystroke in an end's label must not cost every empty note's check).
    private func neededNotesOfRenamedRows(_ relationships: RelationshipIndex) -> Set<ShapeID> {
        notesOfRenamedRows(rowNeeded, relationships)
    }

    private func notesOfRenamedRows(_ held: [RelationshipRowKey: [ShapeID: String]], _ relationships: RelationshipIndex) -> Set<ShapeID> {
        guard !held.isEmpty else { return [] }
        let graph = relationships.graph
        var current: [RelationshipRowKey: Set<String>] = [:]
        for rows in graph.ends.rows.values { for row in rows { current[row.key, default: []].insert(row.name(in: graph.types)) } }
        var found: Set<ShapeID> = []
        for (key, notes) in held {
            for (note, name) in notes where current[key].map({ $0 != [name] }) ?? true { found.insert(note) }
        }
        return found
    }

    private func forgetQuotes(of arrow: ShapeID) {
        guard !quotedBy.isEmpty, let shapes = quotedBy.removeValue(forKey: arrow) else { return }
        for shape in shapes {
            quotes[shape]?.arrows.remove(arrow)
            if quotes[shape]?.arrows.isEmpty == true { quotes[shape] = nil }
        }
    }

    /// An arrow with no type that is not at both ends and is a relationship's loose end: one orange line. Either it
    /// is bound to a relationship type (the type's end of an arrow whose other end was freed), or its relationship
    /// type is gone (deleted, or moved to another board) and it is left bound to a type's note with a name on it or a
    /// rule: an arrow with neither is indistinguishable from a plain arrow that lost an end, and says nothing. A
    /// function of the arrow's record, the marks and which notes are types alone, so it is right after a reopen and
    /// after an undo. The first is not reached while no relationship type exists.
    private func looseEnd(of record: AnyShapeRecord) -> FieldCheck {
        guard let editor, let relationships, editor.registry.relates(record.kind),
              record[TypeSchemaProperty.self] == nil, (record[IsAProperty.self] ?? []).isEmpty else {
            if !looseEnds.isEmpty { looseEnds.remove(record.id) }
            return .clean
        }
        // The cheap guards first: an arrow that says nothing of itself, in a file with no relationship type, reads no
        // more than its own record.
        let active = relationships.isActive
        let speaks = record[RelationshipEndProperty.self] != nil || editor.registry.typeWords(of: record.kind)?.words(record)?.firstLine != nil
        guard active || speaks else {
            if !looseEnds.isEmpty { looseEnds.remove(record.id) }
            return .clean
        }
        let bound = record.boundShapes(in: editor.shapeContext)
        guard !bound.isEmpty, editor.topology?.edges(carriedBy: record.id, view: .literal).contains(where: \.isConnection) != true else {
            if !looseEnds.isEmpty { looseEnds.remove(record.id) }
            return .clean
        }
        let marked = relationships.graph.types.relationshipTypes
        // An end is read through a pill that names a type, as the index reads it.
        let at = bound.compactMap(relationships.typeAt)
        let type = active ? at.first(where: marked.contains) : nil
        guard type != nil || (speaks && !at.isEmpty) else {
            if !looseEnds.isEmpty { looseEnds.remove(record.id) }
            return .clean
        }
        looseEnds.insert(record.id)
        return FieldCheck(problems: [RelationChecks.looseEnd(relation: type, graph: relationships.graph)])
    }

    /// The names the sentences use, from the editor as it is.
    /// Made once: the closures read the editor as it is when a sentence is made, and an arrow's part (10,000 on a first
    /// read) asks for the names whether or not it says anything.
    private func naming(in editor: CanvasEditor) -> RelationNaming {
        if let kept = namingKept { return kept }
        let registry = editor.registry
        let made = RelationNaming(
            label: { [unowned self, weak editor] id in editor.map { label(of: id, in: $0) } ?? "Untitled" },
            directTypes: { [weak editor] id in editor?.types.map { index in index.links(of: id).map(\.shape).filter(index.isType) } ?? [] },
            kindName: { [weak editor] id in
                guard let kind = editor?.shape(inFile: id)?.kind, !registry.isTypeable(kind) else { return nil }
                return registry.label(of: kind).name.lowercased()
            })
        namingKept = made
        return made
    }
    @ObservationIgnored private var namingKept: RelationNaming?

    /// What a shape is called in a sentence: Mentions' label, else `Untitled` and its kind.
    private func label(of id: ShapeID, in editor: CanvasEditor) -> String {
        guard let record = editor.shape(inFile: id) else { return "Untitled" }
        return editor.registry.mentionAppearance(of: record)?.label ?? "Untitled " + editor.registry.label(of: record.kind).name
    }

    /// The index told what a commit changed in relationships: the arrows and notes it names are checked again,
    /// after Validation and the index have both heard, never inside a follower.
    private func relationshipsChanged(_ change: RelationshipChange) {
        revision &+= 1
        guard let editor else { return }
        if change.everything {
            let ids = Set(answers.keys).union(looseEnds)
            editor.validation?.recheck(ids)
            editor.adornmentsDidChange(for: ids)
        } else {
            var ids = change.arrows.union(change.values).union(change.notes)
            // A row renamed: the words of an Only one issue name it, and the partition (which names the notes) is as it was.
            var worded: Set<ShapeID> = []
            if change.rows, let relationships {
                ids.formUnion(notesOfRenamedRows(relationships))
                worded = neededNotesOfRenamedRows(relationships).subtracting(ids)
            }
            if !ids.isEmpty { editor.validation?.recheck(ids) }
            if !worded.isEmpty { editor.validation?.recheckWords(worded) }
            // An arrow's chip is red while an end of it is a misfit: it is made again for the arrows whose verdict may have moved.
            if !change.arrows.isEmpty || !change.values.isEmpty { editor.adornmentsDidChange(for: change.arrows.union(change.values)) }
        }
        editor.setNeedsDisplay()
    }

    /// A commit named a note some sentence quotes: where its label differs from the one quoted (or it is
    /// gone), the arrows that quote it are made again.
    private func requote(_ changes: ChangeSet, in editor: CanvasEditor) {
        var stale: Set<ShapeID> = []
        func look(_ id: ShapeID) {
            guard let held = quotes[id] else { return }
            let now = editor.shape(inFile: id) == nil ? nil : label(of: id, in: editor)
            guard now != held.label else { return }
            stale.formUnion(held.arrows)
            // The label quoted is the one now, so the next commit that names the note compares and finds it the same.
            if let now { quotes[id]?.label = now }
        }
        for id in changes.changed where !changes.moved.contains(id) { look(id) }
        for id in changes.added { look(id) }
        for id in changes.elsewhere { look(id) }
        for id in changes.removed { look(id) }
        guard !stale.isEmpty else { return }
        for arrow in stale { answers[arrow]?.relation?.revision = -1 }
        revision &+= 1
        editor.validation?.recheck(stale)
    }

    // MARK: A run's check

    /// What a checker over a reading was made from: each type it read, as the reading had it. It is a function
    /// of these alone, so it serves any shape of the list while the reading still has them so.
    private struct ScratchRead: Equatable {
        var id: ShapeID
        var text: String?
        var title: String?
        var parents: [ShapeID]
    }

    private struct Scratch {
        var reads: [ScratchRead]
        /// Nil when no type of the list is a type.
        var checker: FieldChecker?
        /// What the checker reads types through.
        var book: FieldBook
    }

    /// The answer for a shape as a reading that hasn't committed has the file (draw's run, a dry run, a
    /// paste), for a shape the reading holds: its values against its types as the reading leaves them, and, for
    /// an arrow of a relationship type, what its ends say as the reading has them.
    /// `typing` is not left out. The committed file's answer when the shape and what it reads are as the
    /// editor keeps them (a script's restated note costs a lookup); the kept checker when only its values
    /// are new; else a checker over the reading, made once for each distinct list and the types' texts and
    /// titles, and let go by the commit. Nothing is kept for the shape.
    public func check(of record: AnyShapeRecord, reading: LayoutReading) -> FieldCheck {
        if let found = checkAndBook(of: record, reading: reading) { return found.check }
        // A shape with no type says one thing: an arrow that is a relationship's loose end, as the reading has the file.
        return reading.isCommitted ? looseEnd(of: record) : looseEnd(of: record, reading: reading)
    }

    /// `looseEnd(of:)` as a reading that hasn't committed has the file: the marks from the run's own graph, which notes
    /// are types and what a pill names from the reading's records, whether the arrow is bound at both ends from its own
    /// record. Nothing is kept for it.
    private func looseEnd(of record: AnyShapeRecord, reading: LayoutReading) -> FieldCheck {
        guard let editor, let relationships, editor.registry.relates(record.kind),
              record[TypeSchemaProperty.self] == nil, (record[IsAProperty.self] ?? []).isEmpty else { return .clean }
        let registry = editor.registry
        let graph = relationships.graph(in: reading)
        let marked = graph.types.relationshipTypes
        let speaks = record[RelationshipEndProperty.self] != nil || registry.typeWords(of: record.kind)?.words(record)?.firstLine != nil
        guard !marked.isEmpty || speaks else { return .clean }
        let bound = record.boundShapes(in: editor.shapeContext)
        guard !bound.isEmpty, !registry.edges(of: record).contains(where: \.isConnection) else { return .clean }
        func isType(_ id: ShapeID) -> Bool {
            guard let shape = reading.shape(inFile: id) else { return false }
            return registry.canBeType(shape.kind) && shape[TypeSchemaProperty.self] != nil
        }
        // An end is read through a pill that names one shape that is a type, as the index reads it.
        let at = bound.compactMap { end -> ShapeID? in
            guard let shape = reading.shape(inFile: end) else { return nil }
            guard relationships.standInKinds.contains(shape.kind) else { return isType(end) ? end : nil }
            let named = Set(relationships.shapesNamed(by: shape))
            guard named.count == 1, let target = named.first, isType(target) else { return nil }
            return target
        }
        let type = at.first(where: marked.contains)
        guard type != nil || (speaks && !at.isEmpty) else { return .clean }
        return FieldCheck(problems: [RelationChecks.looseEnd(relation: type, graph: graph)])
    }

    /// A type's own warnings as a reading that hasn't committed has the file (the rule's third part, for a run): each
    /// type its JSON refers to that the reading no longer has as a type, named as the committed file knows it, and a
    /// `$title` that titles nothing, over the fields the type has in the reading.
    public func typeWarnings(of record: AnyShapeRecord, reading: LayoutReading) -> [String] {
        guard let book, let index, let text = record[TypeSchemaProperty.self]?.text else { return [] }
        if reading.isCommitted {
            var said = goneReferences(of: record.id).map(FieldCheckWords.refersToGone)
            if let problem = TitleSource.problem(book.fields(types: [record.id]), writtenBy: record.id) { said.append(FieldCheckWords.title(problem)) }
            return said
        }
        func isType(_ id: ShapeID) -> Bool {
            guard reading.isChanged(id) else { return index.isType(id) }
            guard let shape = reading.shape(inFile: id) else { return false }
            return reading.registry.canBeType(shape.kind) && shape[TypeSchemaProperty.self] != nil
        }
        let targets = Set(SchemaReferences.refs(in: SchemaReadings.reading(of: text, for: record.id).shownText).map(\.shape))
        // Named and ordered as `goneReferences` does: by the title last known, then by id.
        let gone = targets.filter { !isType($0) }.map { target -> (name: TypeLinkName, key: String, id: String) in
            let title: String?
            switch index.name(of: TypeLink(target)) {
            case .live(let known), .missing(let known): title = known
            }
            return (.missing(lastKnown: title), title?.lowercased() ?? "\u{10FFFF}", target.rawValue.uuidString)
        }.sorted { ($0.key, $0.id) < ($1.key, $1.id) }.map(\.name)
        var said = gone.map(FieldCheckWords.refersToGone)
        let fields = closure(of: [record.id], index: index).contains(where: { differs($0, in: reading, index: index) }) || reading.isChanged(record.id)
            ? FieldBook(reading: reading, record: record, shared: book).fields(types: [record.id]) : book.fields(types: [record.id])
        if let problem = TitleSource.problem(fields, writtenBy: record.id) { said.append(FieldCheckWords.title(problem)) }
        return said
    }

    // MARK: What a run reaches

    /// The shapes whose answer says a type by its name (a rule across fields, an arrow's sentence about its ends): a
    /// type renamed changes their words.
    var shapesNamingATitle: Set<ShapeID> { named }

    /// The arrows whose sentence quotes a note by its label (`“foundation” is a Layer`).
    func arrowsQuoting(_ note: ShapeID) -> Set<ShapeID> { quotes[note]?.arrows ?? [] }

    /// What a change to these types reaches in the committed file: their instances, and the types whose JSON refers to
    /// them, over and over (an instance of a type that refers to a changed type is reached), the types themselves included.
    func reached(byTypes changed: Set<ShapeID>) -> Set<ShapeID> {
        guard let index, !changed.isEmpty else { return [] }
        let references = knownReferences(index)
        var reached = changed, frontier = changed
        while !frontier.isEmpty {
            var next: Set<ShapeID> = []
            for id in frontier {
                for instance in index.instances(of: id) where reached.insert(instance).inserted { next.insert(instance) }
                for referrer in references.referrers[id] ?? [] where reached.insert(referrer).inserted { next.insert(referrer) }
            }
            frontier = next
        }
        return reached
    }

    /// What a run that hasn't committed says of a shape it wrote (draw, a dry run): the check of its values
    /// (`check(of:reading:)`), and the members of `written` no field of its types names, the first of each
    /// object; `typeNames` are its types' titles in its list's order (`Untitled` for one with none).
    /// `unnamed` is empty while any type is gone (its values are kept and not checked), and for a shape
    /// with no types. `written` is nil for a shape whose statement changed nothing.
    public func drawn(_ record: AnyShapeRecord, written: JSONObject?, reading: LayoutReading) -> DrawnFields {
        guard let links = record[IsAProperty.self], !links.isEmpty, record[TypeSchemaProperty.self] == nil,
              let found = checkAndBook(of: record, reading: reading) else { return DrawnFields(check: .clean, unnamed: [], typeNames: []) }
        let types = links.map(\.shape)
        let names = types.map { found.book.name(of: $0) ?? "Untitled" }
        guard let written, !written.isEmpty, types.allSatisfy({ found.book.schemaText(of: $0) != nil }) else {
            return DrawnFields(check: found.check, unnamed: [], typeNames: names)
        }
        return DrawnFields(check: found.check, unnamed: found.book.unnamed(in: written, types: types), typeNames: names)
    }

    /// The check, and the book it read types through: the editor's for the committed file and for types the run
    /// left as they were, a book over the reading for ones it changed.
    private func checkAndBook(of record: AnyShapeRecord, reading: LayoutReading) -> (check: FieldCheck, book: FieldBook)? {
        guard let book, let index, let links = record[IsAProperty.self], !links.isEmpty, record[TypeSchemaProperty.self] == nil else { return nil }
        if reading.isCommitted { return (fullCheck(of: record), book) }
        let types = links.map(\.shape)
        let id = record.id
        // What an arrow's ends say is the run's own: the committed answer's is left out, and the ends the run
        // wrote are read over the run's graph (`RelationshipIndex.graph(in:)`).
        let relation = relationProblems(of: record, links: links, reading: reading)
        func with(_ check: FieldCheck) -> FieldCheck { relation.isEmpty ? check : check.merging(relation) }
        if !closure(of: types, index: index).contains(where: { differs($0, in: reading, index: index) }) {
            if !reading.isChanged(id) { return (with(fullCheck(of: record).removingRelations()), book) }
            return (with(checked(record, by: checker(for: links, revision: index.chainRevision, book: book, index: index), reading: reading)), book)
        }
        if let kept = scratch[types]?.first(where: { $0.reads.allSatisfy { read($0.id, in: reading) == $0 } }) {
            return (with(checked(record, by: kept.checker, reading: reading)), kept.book)
        }
        let over = FieldBook(reading: reading, record: record, shared: book)
        let made = FieldChecker(types: types, book: over)
        #if DEBUG
        scratchMade += 1
        #endif
        let ids = (made?.resolved.order ?? []) + (made?.referencedTypes ?? [])
        if scratchCount >= Self.scratchCapacity {
            scratch = [:]
            scratchCount = 0
        }
        scratch[types, default: []].append(Scratch(reads: ids.map { read($0, in: reading) }, checker: made, book: over))
        scratchCount += 1
        return (with(checked(record, by: made, reading: reading)), over)
    }

    /// What an arrow's ends say of the relationship types in its list, as a reading has the file: a misfit, an
    /// end that cannot be read, a free end. Over the run's own graph, so an end, a type or a note the script
    /// writes is in it. Nothing for a shape that is not an arrow of a kind that relates, or has none of these types.
    private func relationProblems(of record: AnyShapeRecord, links: [TypeLink], reading: LayoutReading) -> [FieldProblem] {
        guard let relationships, let editor else { return [] }
        guard editor.registry.relates(record.kind) else { return noteProblems(of: record, links: links, reading: reading, relationships: relationships) }
        let graph = relationships.graph(in: reading)
        guard links.contains(where: { graph.isRelationshipType($0.shape) }) else { return [] }
        let registry = editor.registry
        let naming = RelationNaming(
            label: { id in
                guard let shape = reading.shape(inFile: id) else { return "Untitled" }
                return registry.mentionAppearance(of: shape)?.label ?? "Untitled " + registry.label(of: shape.kind).name
            },
            directTypes: { id in (graph.types.links[id] ?? []).map(\.shape).filter(graph.types.types.contains) },
            kindName: { id in
                guard let kind = reading.shape(inFile: id)?.kind, !registry.isTypeable(kind) else { return nil }
                return registry.label(of: kind).name.lowercased()
            })
        return RelationChecks.arrow(types: links.map(\.shape), ends: relationships.subjects(of: record, in: reading), graph: graph, naming: naming).problems
    }

    /// What a note's ruled rows lack or hold too many of, as a reading has the file: a note the script draws or changes, or whose
    /// relationships it changes, is judged against the rows and the arrows the run has written (a row the script gives Only one,
    /// a second arrow it draws). Nothing for a kind that draws no rows.
    private func noteProblems(of record: AnyShapeRecord, links: [TypeLink], reading: LayoutReading, relationships: RelationshipIndex) -> [FieldProblem] {
        guard rowKinds.contains(record.kind) else { return [] }
        let graph = relationships.graph(in: reading)
        guard !graph.ends.rows.isEmpty else { return [] }
        let rows = graph.rows(for: links.map(\.shape), isType: false).filter { !$0.rule.isNone }
        guard !rows.isEmpty else { return [] }
        let relations = relationships.relations(of: record.id, in: reading)
        return RelationChecks.note(rows: rows, count: { row in
            var seen: Set<ShapeID> = []
            return relations.filter { $0.type == row.key.type && row.sides.contains($0.side) && seen.insert($0.arrow).inserted }.count
        }, graph: graph)
    }

    /// The validator's answer over the reading.
    private func checked(_ record: AnyShapeRecord, by checker: FieldChecker?, reading: LayoutReading) -> FieldCheck {
        guard let checker else { return .clean }
        if let values = record[FieldValuesProperty.self], !values.isEmpty {
            #if DEBUG
            checksMade += 1
            #endif
            return checker.check(values)
        }
        return checker.emptyCheck(names: names)
    }

    private func read(_ id: ShapeID, in reading: LayoutReading) -> ScratchRead {
        let shape = reading.shape(inFile: id)
        return ScratchRead(id: id, text: shape?[TypeSchemaProperty.self]?.text, title: shape.flatMap { reading.registry.title(of: $0) },
                           parents: shape?[IsAProperty.self]?.map(\.shape) ?? [])
    }

    /// Whether a type the committed index knows (or doesn't) is not as the reading has it. A type that the
    /// file never had or lost and the reading hasn't either differs in nothing.
    private func differs(_ id: ShapeID, in reading: LayoutReading, index: TypeIndex) -> Bool {
        reading.isChanged(id) && (reading.shape(inFile: id) != nil || index.isType(id))
    }

    /// The types a list reads, as the committed file has them: itself, what each builds on, and the types their
    /// JSON refers to, over and over.
    private func closure(of types: [ShapeID], index: TypeIndex) -> [ShapeID] {
        if closures.revision != index.chainRevision || closures.byList.count >= Self.capacity { closures = (index.chainRevision, [:]) }
        if let kept = closures.byList[types] { return kept }
        let references = knownReferences(index)
        var seen: Set<ShapeID> = [], found: [ShapeID] = [], frontier = types
        while let next = frontier.popLast() {
            guard seen.insert(next).inserted else { continue }
            found.append(next)
            frontier += index.graph.lineage(of: next)
            frontier += references.targets[next] ?? []
        }
        closures.byList[types] = found
        return found
    }

    /// The checker for a shape's list. Notes made in a row mostly share a list, so the last answer is kept
    /// (a first read of thousands of notes maps and hashes a list once, not each time).
    private func checker(for links: [TypeLink], revision: Int, book: FieldBook, index: TypeIndex) -> FieldChecker? {
        if let recent, recent.revision == revision, recent.links == links { return recent.checker }
        let found = checker(for: links.map(\.shape), book: book, index: index)
        recent = (links, revision, found)
        return found
    }

    /// The checker for a list, made current (or made); nil when no type of the list is a type.
    private func checker(for types: [ShapeID], book: FieldBook, index: TypeIndex) -> FieldChecker? {
        if let kept = checkers[types] {
            if kept.stamp == index.chainRevision { return kept }
            if kept.isCurrent() {
                kept.stamp = index.chainRevision
                return kept
            }
        }
        guard let made = FieldChecker(types: types, book: book) else {
            checkers[types] = nil
            return nil
        }
        #if DEBUG
        checkersMade += 1
        #endif
        if checkers.count >= Self.capacity {
            checkers = [:]
            recent = nil
        }
        checkers[types] = made
        return made
    }

    /// Set by whoever has the caret in a field (a row, a card's cell, a panel's box) when it gets it, and
    /// nil when it leaves: one at a time, and only whoever set it clears it. The field being typed in is
    /// left out of every read, so what is half typed is never red. Setting it checks the shape again
    /// (the ring and the dot follow the caret) and redraws.
    public var typing: (shape: ShapeID, path: FieldPath)? {
        get { typingStorage }
        set {
            let old = typingStorage
            if old?.shape == newValue?.shape, old?.path == newValue?.path { return }
            typingStorage = newValue
            revision &+= 1
            let shapes = Set([old?.shape, newValue?.shape].compactMap { $0 })
            editor?.validation?.recheck(shapes)
            editor?.setNeedsDisplay()
            // An open form shows the answer less the cell with the caret: it looks again, a turn later.
            for told in typingObservers { told() }
        }
    }

    /// Calls `body` after each change of `typing`, which moves what `check(of:)` says with no commit: the forms'
    /// service (`FieldCards`, registered after this one) has its open forms look again.
    func onTypingChange(_ body: @escaping @MainActor () -> Void) { typingObservers.append(body) }

    /// Moves when any answer or `typing` changes.
    public private(set) var revision = 0

    // MARK: A type changed

    /// A type came, went, or changed its schema, its own types or its name. After the index has taken
    /// the commit in, so Validation is told what to check again: the rule has no `affected:`, which
    /// would run before the index heard.
    private func typesChanged(_ changed: Set<ShapeID>) {
        guard let editor, let index = editor.types else { return }
        let before = lastChain
        lastChain = index.chainRevision
        names &+= 1
        revision &+= 1
        // Only names changed: nothing is reached but the answers that say one.
        guard index.chainRevision != before else {
            editor.validation?.recheck(named)
            return
        }
        let references = knownReferences(index, changing: changed)
        var reached = changed, frontier = changed
        while !frontier.isEmpty {
            var next: Set<ShapeID> = []
            for id in frontier {
                for instance in index.instances(of: id) where reached.insert(instance).inserted { next.insert(instance) }
                for referrer in references.referrers[id] ?? [] where reached.insert(referrer).inserted { next.insert(referrer) }
            }
            frontier = next
        }
        // An instance whose answer's checker is still current once asked (the edit changed nothing the check reads of
        // it: a description, a title, a field it doesn't have) keeps its answer, and the rules aren't asked of it again.
        // The price: each reached list is made current inside the commit and not at the next read.
        if let book {
            let revision = index.chainRevision
            reached = reached.filter { id in
                guard !changed.contains(id), !named.contains(id), let answer = answers[id], let kept = answer.checker else { return true }
                return checker(for: answer.links, revision: revision, book: book, index: index) !== kept
            }
        }
        // The sentences that name a type say it as the chain has it now: a type of an end that lost its schema or
        // went, or was renamed in the commit that changed the chain. The arrows that say one are not instances
        // of the type.
        reached.formUnion(named.filter { answers[$0]?.relation?.names != nil })
        editor.validation?.recheck(reached)
        editor.setNeedsDisplay()
    }

    /// The references, made when first needed from every type, then kept up to date for the types that
    /// changed. A target that is gone stays in both directions.
    private func knownReferences(_ index: TypeIndex, changing changed: Set<ShapeID> = []) -> TypeReferences {
        var made = references ?? TypeReferences()
        for type in references == nil ? index.types : changed {
            made.set(type, refersTo: index.isType(type) ? Self.targets(of: type, in: index) : [])
        }
        references = made
        return made
    }

    private static func targets(of type: ShapeID, in index: TypeIndex) -> Set<ShapeID> {
        guard let text = index.schemaText(of: type) else { return [] }
        return Set(SchemaReferences.refs(in: SchemaReadings.reading(of: text, for: type).shownText).map(\.shape))
    }

    /// The types a type's JSON refers to that are gone, as they are named: by the title they were last
    /// known by, ordered by it and then by id, each once.
    func goneReferences(of type: ShapeID) -> [TypeLinkName] {
        guard let index = editor?.types else { return [] }
        let targets = knownReferences(index).targets[type] ?? []
        return targets.filter { !index.isType($0) }.map { target -> (name: TypeLinkName, key: String, id: String) in
            let name = index.name(of: TypeLink(target))
            if case .missing(let lastKnown?) = name { return (name, lastKnown.lowercased(), target.rawValue.uuidString) }
            return (name, "\u{10FFFF}", target.rawValue.uuidString)
        }.sorted { ($0.key, $0.id) < ($1.key, $1.id) }.map(\.name)
    }
}

extension FieldChecks: EditorService {
    /// Forgets the answers of shapes the file no longer holds, and moves `revision` when a shape that has an
    /// answer changed. It reads no record and checks nothing: a check is made when asked (the rule's read
    /// after the commit, a row's draw). A shape that only moved changes nothing the check reads.
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        if scratchCount > 0 { dropScratch() }
        guard !answers.isEmpty || typingStorage != nil else { return }
        // A file put in place on the board shown (a board read again, a revert): the answers are another file's.
        if changes.replacedDocument {
            answers = [:]
            named = []
            quotes = [:]
            quotedBy = [:]
            looseEnds = []
            rowErrors = [:]
            rowNeeded = [:]
            rowErrorKeys = [:]
            typingStorage = nil
            revision &+= 1
            return
        }
        if !quotes.isEmpty { requote(changes, in: editor) }
        var moved = false
        func forget(_ id: ShapeID) {
            guard editor.file.record(id) == nil else { return }
            if answers.removeValue(forKey: id) != nil { moved = true }
            forgetQuotes(of: id)
            looseEnds.remove(id)
            forgetRowErrors(of: id)
            named.remove(id)
            if typingStorage?.shape == id {
                typingStorage = nil
                moved = true
            }
        }
        for id in changes.removed { forget(id) }
        for id in changes.elsewhere { forget(id) }
        if !moved { moved = changes.changed.contains { !changes.moved.contains($0) && answers[$0] != nil } }
        if !moved { moved = changes.elsewhere.contains { answers[$0] != nil } }
        if moved { revision &+= 1 }
    }

    private func dropScratch() {
        scratch = [:]
        scratchCount = 0
    }

    /// A switch alone keeps every answer: they are the file's. A file put in place drops them, the
    /// checkers and the references, which are another file's.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        if scratchCount > 0 { dropScratch() }
        var moved = typingStorage != nil
        // The board left holds this shape's answer, made with the path left out: it is checked again when taken back.
        if let left = typingStorage?.shape { editor.validation?.recheck([left]) }
        typingStorage = nil
        if change.isFileReplaced {
            answers = [:]
            quotes = [:]
            quotedBy = [:]
            rowErrors = [:]
            rowNeeded = [:]
            rowErrorKeys = [:]
            checkers = [:]
            recent = nil
            references = nil
            named = []
            names &+= 1
            lastChain = editor.types?.chainRevision ?? 0
            moved = true
        }
        if moved { revision &+= 1 }
    }

    /// The shape's editing ended: a caret that was in one of its fields is not any more (a net under the
    /// row's own nil), and its ring is Validation's to draw now.
    public func editingDidEnd(_ id: ShapeID, in editor: CanvasEditor) {
        guard typingStorage?.shape == id else { return }
        typingStorage = nil
        revision &+= 1
        editor.validation?.recheck([id])
    }
}

extension CanvasEditor {
    /// What the check says of a shape's values (`FieldChecks`); nil without TypesPlugin.
    public var fieldChecks: FieldChecks? { service(FieldChecks.self) }
}
