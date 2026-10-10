import Canvas
import Foundation
import Observation
import Validation

/// The types that refer to each other, by their JSON: a `$ref` to a type's URI, with or without a
/// fragment, and a pointer's `contentSchema`. Both ways, so an edit to a type reaches the types that
/// refer to it and a type that is gone still knows who waits for it.
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
        var check: FieldCheck
    }

    @ObservationIgnored private weak var editor: CanvasEditor?
    @ObservationIgnored private var answers: [ShapeID: Answer] = [:]
    @ObservationIgnored private var checkers: [[ShapeID]: FieldChecker] = [:]
    @ObservationIgnored private var references: TypeReferences?
    @ObservationIgnored private var typingStorage: (shape: ShapeID, path: FieldPath)?
    /// Moves when any type was renamed: an answer that names a type is made again.
    @ObservationIgnored private var names = 0
    /// The shapes whose answer names a type.
    @ObservationIgnored private var named: Set<ShapeID> = []
    @ObservationIgnored private var lastChain: Int

    #if DEBUG
    /// How many checkers have been made, and how many values checked (debug builds only): tests hold
    /// them to one for each distinct list and one for each changed shape.
    @ObservationIgnored public private(set) var checkersMade = 0
    @ObservationIgnored public private(set) var checksMade = 0
    #endif

    /// The most lists kept; past it all are dropped.
    private static let capacity = 1_024

    public init(editor: CanvasEditor) {
        self.editor = editor
        lastChain = editor.types?.chainRevision ?? 0
        editor.types?.onChange { [weak self] changed in self?.typesChanged(changed) }
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
        guard let editor, let book = editor.fieldBook, let index = editor.types,
              let links = record[IsAProperty.self], !links.isEmpty, record[TypeSchemaProperty.self] == nil, !record.isOpaque else { return .clean }
        let values = record[FieldValuesProperty.self]
        let id = record.id
        let old = answers[id]
        if let old, old.links == links, old.values == values {
            if let checker = old.checker {
                if checker.stamp == book.revision, old.nameStamp == nil || old.nameStamp == names { return old.check }
            } else if old.stamp == book.revision {
                return old.check
            }
        }
        let checker = checker(for: links.map(\.shape), book: book, index: index)
        let check: FieldCheck
        if let old, let checker, old.checker === checker, old.links == links, old.values == values, old.nameStamp == nil || old.nameStamp == names {
            check = old.check
        } else if let checker {
            if let values, !values.isEmpty {
                #if DEBUG
                checksMade += 1
                #endif
                check = checker.check(values)
            } else {
                check = checker.emptyCheck
            }
        } else {
            check = .clean
        }
        let namesAType = check.problems.contains { $0.path.isRoot }
        if namesAType { named.insert(id) } else { named.remove(id) }
        answers[id] = Answer(links: links, values: values, checker: checker, stamp: book.revision, nameStamp: namesAType ? names : nil, check: check)
        return check
    }

    /// The checker for a list, made current (or made); nil when no type of the list is a type.
    private func checker(for types: [ShapeID], book: FieldBook, index: TypeIndex) -> FieldChecker? {
        if let kept = checkers[types] {
            if kept.stamp == book.revision { return kept }
            if kept.isCurrent() {
                kept.stamp = book.revision
                return kept
            }
        }
        guard let made = FieldChecker(types: types, book: book, index: index) else {
            checkers[types] = nil
            return nil
        }
        #if DEBUG
        checkersMade += 1
        #endif
        if checkers.count >= Self.capacity { checkers = [:] }
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
        }
    }

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
        guard !answers.isEmpty || typingStorage != nil else { return }
        // A file put in place on the board shown (a board read again, a revert): the answers are another file's.
        if changes.replacedDocument {
            answers = [:]
            named = []
            typingStorage = nil
            revision &+= 1
            return
        }
        var moved = false
        func forget(_ id: ShapeID) {
            guard editor.file.record(id) == nil else { return }
            if answers.removeValue(forKey: id) != nil { moved = true }
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

    /// A switch alone keeps every answer: they are the file's. A file put in place drops them, the
    /// checkers and the references, which are another file's.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        var moved = typingStorage != nil
        typingStorage = nil
        if change.isFileReplaced {
            answers = [:]
            checkers = [:]
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
