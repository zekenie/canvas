import Canvas
import Foundation
import Observation
import Titles
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
        var check: FieldCheck
        /// What an answer with pointers also depends on; nil (one field, no reference to retain) for the rest.
        var link: LinkPart?
    }

    /// The validator's part of an answer whose list has pointers and whose note holds values (`check` is this and
    /// the pointers' problems together), the targets the pointers named with their link revisions when it was made
    /// (`FieldBook.linkRevision`) and the chain's revision then: the answer is current only while both are.
    private final class LinkPart {
        let base: FieldCheck
        let targets: [ShapeID: Int]
        let chain: Int
        init(base: FieldCheck, targets: [ShapeID: Int], chain: Int) {
            self.base = base
            self.targets = targets
            self.chain = chain
        }
    }

    @ObservationIgnored private weak var editor: CanvasEditor?
    /// The services it reads, found once: a frame asks for each note in view, and a lookup by type costs more than the rest of an ask.
    @ObservationIgnored private let book: FieldBook?
    @ObservationIgnored private let index: TypeIndex?
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

    #if DEBUG
    /// How many checkers have been made, and how many values checked (debug builds only): tests hold
    /// them to one for each distinct list and one for each changed shape.
    @ObservationIgnored public private(set) var checkersMade = 0
    @ObservationIgnored public private(set) var checksMade = 0
    /// How many checkers a run made over a reading (`check(of:reading:)`).
    @ObservationIgnored public private(set) var scratchMade = 0
    /// How many times the pointers' part of an answer was made (the validator's is `checksMade`).
    @ObservationIgnored public private(set) var linkChecksMade = 0
    #endif

    /// The most lists kept; past it all are dropped.
    private static let capacity = 1_024
    /// The most checkers a run keeps for types it changes.
    private static let scratchCapacity = 16

    public init(editor: CanvasEditor) {
        self.editor = editor
        book = editor.fieldBook
        index = editor.types
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
        // (An opaque shape holds nothing typed, so it has no `is` and is passed here.) The book's revision is the index's
        // stamp, read from the index at hand: the book finds it by a lookup of the service.
        guard let book, let index, let links = record[IsAProperty.self], !links.isEmpty, record[TypeSchemaProperty.self] == nil else { return .clean }
        let revision = index.chainRevision
        let values = record[FieldValuesProperty.self]
        let id = record.id
        let old = answers[id]
        if let old, old.links == links, old.values == values {
            if let checker = old.checker {
                if checker.stamp == revision, old.nameStamp == nil || old.nameStamp == names {
                    if isCurrent(old, at: revision) { return old.check }
                    return relinked(old, of: id, checker: checker, revision: revision)
                }
            } else if old.stamp == revision {
                return old.check
            }
        }
        let checker = self.checker(for: links, revision: revision, book: book, index: index)
        var check: FieldCheck
        if let old, let checker, old.checker === checker, old.links == links, old.values == values, old.nameStamp == nil || old.nameStamp == names {
            check = old.link?.base ?? old.check
        } else if let checker {
            if let values, !values.isEmpty {
                #if DEBUG
                checksMade += 1
                #endif
                check = checker.check(values)
            } else {
                check = checker.emptyCheck(names: names)
            }
        } else {
            check = .clean
        }
        let namesAType = check.problems.contains { $0.path.isRoot }
        if namesAType { named.insert(id) } else if !named.isEmpty { named.remove(id) }
        var answer = Answer(links: links, values: values, checker: checker, stamp: revision, nameStamp: namesAType ? names : nil, check: check)
        if let checker, !checker.linkSites.isEmpty, let values, !values.isEmpty {
            link(&answer, base: check, values: values, checker: checker, revision: revision)
            check = answer.check
        }
        answers[id] = answer
        return check
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
    /// paste), for a shape the reading holds: its values against its types as the reading leaves them.
    /// `typing` is not left out. The committed file's answer when the shape and what it reads are as the
    /// editor keeps them (a script's restated note costs a lookup); the kept checker when only its values
    /// are new; else a checker over the reading, made once for each distinct list and the types' texts and
    /// titles, and let go by the commit. Nothing is kept for the shape.
    public func check(of record: AnyShapeRecord, reading: LayoutReading) -> FieldCheck {
        checkAndBook(of: record, reading: reading)?.check ?? .clean
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
        if !closure(of: types, index: index).contains(where: { differs($0, in: reading, index: index) }) {
            if !reading.isChanged(id) {
                let full = fullCheck(of: record)
                // The kept answer's pointers are the committed file's: one whose target the run drew, changed or
                // deleted (or a type that target is) is said again over the reading, the validator's part kept.
                guard let answer = answers[id], let part = answer.link, let checker = answer.checker, let values = answer.values,
                      part.targets.keys.contains(where: { targetDiffers($0, in: reading, index: index) }) else { return (full, book) }
                return (checker.merged(part.base, with: linkProblems(of: record, values: values, by: checker, reading: reading)), book)
            }
            return (checked(record, by: checker(for: links, revision: index.chainRevision, book: book, index: index), reading: reading), book)
        }
        if let kept = scratch[types]?.first(where: { $0.reads.allSatisfy { read($0.id, in: reading) == $0 } }) {
            return (checked(record, by: kept.checker, reading: reading), kept.book)
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
        return (checked(record, by: made, reading: reading), over)
    }

    /// The validator's answer and the pointers', over the reading: a pointer to a note the run draws is one,
    /// to a note it deletes gone.
    private func checked(_ record: AnyShapeRecord, by checker: FieldChecker?, reading: LayoutReading) -> FieldCheck {
        guard let checker else { return .clean }
        if let values = record[FieldValuesProperty.self], !values.isEmpty {
            #if DEBUG
            checksMade += 1
            #endif
            let base = checker.check(values)
            guard checker.holdsLinks else { return base }
            return checker.merged(base, with: linkProblems(of: record, values: values, by: checker, reading: reading))
        }
        return checker.emptyCheck(names: names)
    }

    private func linkProblems(of record: AnyShapeRecord, values: FieldValues, by checker: FieldChecker, reading: LayoutReading) -> [FieldProblem] {
        #if DEBUG
        linkChecksMade += 1
        #endif
        return checker.linkProblems(in: values) { target, type in linkState(target, as: type, reading: reading, record: record) }
    }

    /// Whether a pointer's target, or a type it is or builds on as the committed file has it, is not as the reading has it.
    private func targetDiffers(_ target: ShapeID, in reading: LayoutReading, index: TypeIndex) -> Bool {
        reading.isChanged(target) || index.graph.lineage(of: target).contains { differs($0, in: reading, index: index) }
    }

    /// What a pointer's target is to the type it points at, as a reading has the file: a shape the reading lacks is
    /// gone unless the committed file can't read it either (kept aside, on a board it can't show); one it holds is
    /// a note of the type while it holds no schema and its `is` lists, as the reading has them, reach the type.
    private func linkState(_ target: ShapeID, as type: ShapeID, reading: LayoutReading, record: AnyShapeRecord) -> LinkState {
        func shape(_ id: ShapeID) -> AnyShapeRecord? { id == record.id ? record : reading.shape(inFile: id) }
        guard let found = shape(target) else {
            guard let editor, editor.file.board(containing: target) != nil else { return .gone }
            let committed = editor.shape(inFile: target)
            return committed == nil || committed?.isOpaque == true ? .elsewhere : .gone
        }
        guard !found.isOpaque else { return .elsewhere }
        guard found[TypeSchemaProperty.self] == nil, shape(type)?[TypeSchemaProperty.self] != nil else { return .notOne }
        var seen: Set<ShapeID> = [target], frontier = [target]
        while let next = frontier.popLast() {
            for parent in shape(next)?[IsAProperty.self]?.map(\.shape) ?? [] {
                if parent == type { return .one }
                if seen.insert(parent).inserted { frontier.append(parent) }
            }
        }
        return .notOne
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

    /// Whether an answer's pointers still say what they said: the chain (what makes a note a Person, and whether
    /// the type a pointer points at is one) is the one it was made at, and no target changed its state. An
    /// answer with no pointer is, at one nil compare.
    private func isCurrent(_ answer: Answer, at revision: Int) -> Bool {
        guard let part = answer.link, let book else { return true }
        // Before the targets: values that are no links name none, but their pointer's type may have gone or come back.
        guard part.chain == revision else { return false }
        return part.targets.allSatisfy { book.linkRevision(of: $0.key) == $0.value }
    }

    /// An answer whose validator's part is right and whose pointers' is not: that part made again, the
    /// validator not asked.
    private func relinked(_ old: Answer, of id: ShapeID, checker: FieldChecker, revision: Int) -> FieldCheck {
        var answer = old
        if let values = old.values, let part = old.link { link(&answer, base: part.base, values: values, checker: checker, revision: revision) }
        answers[id] = answer
        return answer.check
    }

    /// Sets the answer's check to its pointers' problems merged with its validator's (`base`), and keeps the targets it
    /// read and their revisions. Each target read goes through the book's `remember`, so a commit that changes one
    /// finds this note.
    private func link(_ answer: inout Answer, base: FieldCheck, values: FieldValues, checker: FieldChecker, revision: Int) {
        guard let book else { return }
        #if DEBUG
        linkChecksMade += 1
        #endif
        var targets: [ShapeID: Int] = [:]
        let problems = checker.linkProblems(in: values) { target, type in
            targets[target] = book.linkRevision(of: target)
            return linkState(target, as: type)
        }
        answer.check = checker.merged(base, with: problems)
        answer.link = LinkPart(base: base, targets: targets, chain: revision)
    }

    /// What a pointer's target is to the type it points at, as the editor holds the file.
    private func linkState(_ target: ShapeID, as type: ShapeID) -> LinkState {
        guard let editor, let index else { return .elsewhere }
        book?.remember(target)
        guard editor.file.board(containing: target) != nil else { return .gone }
        guard let record = editor.shape(inFile: target), !record.isOpaque else { return .elsewhere }
        return FieldLinks.admits(record.id, as: type, in: index) ? .one : .notOne
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
                // An answer with pointers also depends on what they point at and on whether their type is one, which its
                // checker doesn't say: it is checked again, though its values name no target.
                guard !changed.contains(id), !named.contains(id), let answer = answers[id], answer.link == nil, let kept = answer.checker else { return true }
                return checker(for: answer.links, revision: revision, book: book, index: index) !== kept
            }
            // The notes that point at a note this makes, or stops making, an instance of what they point at, though
            // they are no instance of what changed.
            if book.tracksTargets { reached.formUnion(book.linkCarriers(ofTargetsIn: index.affected(by: changed))) }
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
        if scratchCount > 0 { dropScratch() }

        // The notes that point at a note this commit changed what is said of (gone, back, renamed, no longer one): before the
        // early return, since the book's revisions must move whether or not an answer is kept. Their answers follow
        // by the target's revision, and Validation looks at them again.
        if let carriers = editor.fieldBook?.linkCarriers(touchedBy: changes), !carriers.isEmpty {
            editor.validation?.recheck(carriers)
            revision &+= 1
        }
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
