@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import Queries
import TestKit
import Titles
import Topology
import Types
import Validation

// The index kept by commits against the index read from the file: after every step of a seeded run of
// edits and undos, a second editor opened on the same file reads the same ends and rows, and whatever
// the step changed in them was told. And, for a run whose arrows are of relationship types, the verdict on
// each arrow: what Validation holds of it, kept by the commits and never run afresh, is the pure verdict of
// a fresh read of the file, the arrow's own check included, after every step, and so is the set `:misfit` lists.

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// What the index says of the shapes a run keeps an eye on.
@MainActor private struct Reading {
    var bonds: [ShapeID: String] = [:]
    var notes: [ShapeID: String] = [:]
    var rows: [ShapeID: [RelationshipRow]] = [:]
    /// What the kept index says of a note's ruled rows, and the record the note had: a verdict that moved with the record unchanged
    /// was a change the index had to name.
    var verdicts: [ShapeID: String] = [:]
    var records: [ShapeID: AnyShapeRecord] = [:]

    init(_ editor: CanvasEditor, bonds bondIDs: [ShapeID], notes noteIDs: [ShapeID], types typeIDs: [ShapeID], skippingTypes: Bool = false) {
        guard let index = editor.relationships else { return }
        for id in noteIDs where editor.shape(inFile: id) != nil {
            // The kinds of problem and no words: a row renamed with every ruled row's partition equal says the same thing in other words,
            // which the index announces as a redraw and the check meets (Validation's issue is held to the words in `verdictDifference`).
            if let verdict = noteVerdict(editor, id) { verdicts[id] = verdict.map { "\($0.kind)" }.joined(separator: " | ") }
            records[id] = editor.shape(inFile: id)
        }
        for id in bondIDs where editor.shape(inFile: id) != nil {
            let end = index.end(id)
            bonds[id] = "\(String(describing: end?.type)) \(String(describing: end?.side)) \(index.fits(of: id).map { "\($0.type) \($0.fit)" })"
        }
        // A type is no note: the arrows typed with a relationship type that end at it are its own business.
        for id in noteIDs where editor.shape(inFile: id) != nil && !(skippingTypes && editor.types?.isType(id) == true) {
            notes[id] = "\(index.relations(of: id).map { "\($0.arrow) \($0.type) \($0.side) \($0.far)" })"
        }
        for id in typeIDs where editor.shape(inFile: id) != nil && editor.types?.isType(id) == true {
            rows[id] = index.graph.rows(for: [id], isType: false)
        }
    }
}

/// What a note's ruled rows say of it, from the index `editor` keeps: nil for a shape that is not a note that draws rows, with a type
/// or no `is`.
@MainActor private func noteVerdict(_ editor: CanvasEditor, _ id: ShapeID) -> [FieldProblem]? {
    guard let record = editor.shape(inFile: id), record.typed(as: RowSlip.self) != nil, record[TypeSchemaProperty.self] == nil,
          let list = record[IsAProperty.self], !list.isEmpty, let index = editor.relationships, index.isActive else { return nil }
    return RelationChecks.note(rows: index.ruledRows(for: list.map(\.shape)), count: { index.relations(of: id, in: $0).count }, graph: index.graph)
}

/// The registries the runs put their editors over, each made once for every step of every run: what a fresh read tests is the
/// editor's indexes made from the file, and the plugins' registering is the same each time. The plain one is the editors that read
/// a file afresh (and the runs that don't ask queries); the typed one adds the queries and the lock the typed runs use.
@MainActor private var registries: [Bool: Registry] = [:]

@MainActor private func registry(typed: Bool) throws -> Registry {
    if !typed { return try sharedBondRegistry() }
    if let known = registries[typed] { return known }
    let made = try bondRegistry(more: typed ? [QueriesPlugin(), TitleQueriesPlugin(), ValidationQueriesPlugin(), TypeQueriesPlugin(), FreezingPlugin()] : [])
    registries[typed] = made
    return made
}

/// What a file read afresh says, worked out once for each arrow and note of it: the pure verdicts are functions of the file.
@MainActor private final class FreshVerdicts {
    /// What the pure check says of an arrow (`expectedIssues`).
    var arrows: [ShapeID: [String]] = [:]
    /// What the check of the file read afresh says of a shape: its full check.
    var checks: [ShapeID: FieldCheck] = [:]
    /// What a note's ruled rows say of it (`noteVerdict`); the note has none to say when it is no note that draws rows.
    var notes: [ShapeID: [FieldProblem]?] = [:]
}

/// The editors that read a run's files afresh, over the plain registry, each given again for a file it has read.
@MainActor private func freshReads() throws -> FreshReads<FreshVerdicts> {
    let registry = try registry(typed: false)
    return FreshReads(memo: FreshVerdicts.init) { bondEditor(registry: registry, file: $0) }
}

/// How the kept index differs from the one of `reader`, an editor opened on the same file; nil when it does not.
@MainActor private func difference(_ editor: CanvasEditor, bonds: [ShapeID], reader: CanvasEditor) throws -> String? {
    let fresh = try require(reader.relationships), kept = try require(editor.relationships)
    if kept.isActive != fresh.isActive { return "isActive \(kept.isActive) against \(fresh.isActive)" }
    for type in editor.types?.graph.relationshipTypes ?? [] where kept.graph.sides(of: type) != fresh.graph.sides(of: type) {
        return "the sides of \(type.rawValue.uuidString.prefix(4)): kept \(kept.graph.sides(of: type)) against fresh \(fresh.graph.sides(of: type))"
    }
    for id in bonds where editor.shape(inFile: id) != nil {
        let x = kept.end(id), y = fresh.end(id)
        if x?.type != y?.type || x?.side != y?.side { return "end(\(id.rawValue.uuidString.prefix(4))) \(String(describing: x)) against \(String(describing: y))" }
    }
    return kept.graph.ends.rows == fresh.graph.ends.rows ? nil : "the rows differ"
}

/// How many verdicts the runs below judged of an arrow its relationship type was taken from.
@MainActor private var leftBehind = 0

/// What the pure check says of an arrow in a file read afresh (and nothing else of it), as Validation holds
/// it: `error to message`, `warning - message`, sorted. The loose end is the arrow's own record's.
@MainActor private func expectedIssues(of id: ShapeID, in fresh: CanvasEditor) throws -> [String] {
    let relationships = try require(fresh.relationships), types = try require(fresh.types)
    let record = try require(fresh.file.record(id))
    let graph = relationships.graph
    let list = record[IsAProperty.self]?.map(\.shape) ?? []
    var problems: [FieldProblem] = []
    if list.isEmpty {
        let bond = try require(record.typed(as: Bond.self)?.props)
        // An end is the type it stands at: a note that is one, or a pill that names one shape that is.
        func typeBehind(_ id: ShapeID) -> ShapeID? {
            guard let end = fresh.shape(inFile: id) else { return nil }
            guard fresh.registry.standIns.kinds.contains(end.kind) else { return types.isType(id) ? id : nil }
            guard case .shapes(let named)? = fresh.registry.standIns.forwarding(of: end), Set(named).count == 1, let target = named.first, types.isType(target) else { return nil }
            return target
        }
        let bound = [bond.from, bond.to].compactMap { $0 }.compactMap(typeBehind)
        if bond.from == nil || bond.to == nil {
            if let type = bound.first(where: graph.types.relationshipTypes.contains) {
                problems = [RelationChecks.looseEnd(relation: type, graph: graph)]
            } else if (fresh.registry.typeWords(of: record.kind)?.words(record)?.firstLine != nil || record[RelationshipEndProperty.self] != nil),
                      !bound.isEmpty {
                // Its relationship type is gone and it is left at a type's note with a name on it or a rule.
                problems = [RelationChecks.looseEnd(relation: nil, graph: graph)]
                leftBehind += 1
            }
        }
    } else {
        let registry = fresh.registry
        let naming = RelationNaming(
            label: { id in
                guard let record = fresh.shape(inFile: id) else { return "Untitled" }
                return registry.mentionAppearance(of: record)?.label ?? "Untitled"
            },
            directTypes: { types.links(of: $0).map(\.shape).filter(types.isType) },
            kindName: { id in
                guard let kind = fresh.shape(inFile: id)?.kind, !registry.isTypeable(kind) else { return nil }
                return registry.label(of: kind).name.lowercased()
            })
        problems = RelationChecks.arrow(types: list, ends: relationships.subjects(of: id), graph: graph, naming: naming).problems
    }
    return problems.map { "\($0.kind == .wrong ? "error" : $0.kind == .needed ? "incomplete" : "warning") \($0.placeName ?? "-") \($0.message)" }.sorted()
}

/// Every arrow of the run: the check of a fresh read of the file is the pure verdict, and what the editor's
/// Validation holds for an arrow on the board shown is the same.
@MainActor private func verdictDifference(_ editor: CanvasEditor, bonds: [ShapeID], notes: [ShapeID], read: FreshReads<FreshVerdicts>.Read) throws -> String? {
    let fresh = read.editor
    let checks = try require(fresh.fieldChecks)
    /// The full check of a shape of the file read afresh, worked out once.
    func fullCheck(of record: AnyShapeRecord) -> FieldCheck {
        if let known = read.memo.checks[record.id] { return known }
        let made = checks.fullCheck(of: record)
        read.memo.checks[record.id] = made
        return made
    }
    var misfits: Set<ShapeID> = []
    for id in bonds {
        guard let record = fresh.shape(inFile: id) else { continue }
        let expected: [String]
        if let known = read.memo.arrows[id] {
            expected = known
        } else {
            expected = try expectedIssues(of: id, in: fresh)
            read.memo.arrows[id] = expected
        }
        if expected.contains(where: { $0.hasPrefix("error ") }) { misfits.insert(id) }
        let said = fullCheck(of: record).problems.map { "\($0.kind == .wrong ? "error" : $0.kind == .needed ? "incomplete" : "warning") \($0.placeName ?? "-") \($0.message)" }.sorted()
        if said != expected { return "the check of \(id.rawValue.uuidString.prefix(4)) says \(said), the pure verdict \(expected)" }
        guard editor.document[id] != nil else { continue }
        let kept = editor.issues(id).map(word).sorted()
        if kept != expected { return "Validation holds \(kept) of \(id.rawValue.uuidString.prefix(4)), the pure verdict \(expected)" }
    }
    // The notes: what the check, Validation and `:incomplete` hold of a note's ruled rows is the pure verdict of the file read afresh.
    var needy: Set<ShapeID> = []
    for id in notes {
        guard let record = fresh.shape(inFile: id) else { continue }
        let verdict: [FieldProblem]?
        if let known = read.memo.notes[id] {
            verdict = known
        } else {
            verdict = noteVerdict(fresh, id)
            read.memo.notes[id] = .some(verdict)
        }
        let expected = verdict ?? []
        if expected.contains(where: { $0.kind == .needed }) { needy.insert(id) }
        let said = fullCheck(of: record).problems.filter { if case .row = $0.locus { true } else { false } }
        if said != expected { return "the check of note \(id.rawValue.uuidString.prefix(4)) says \(said.map(\.message)), the pure verdict \(expected.map(\.message))" }
        guard editor.document[id] != nil else { continue }
        let errors = editor.issues(id).filter { $0.severity == .error }.map(\.message).sorted()
        let wrong = expected.filter { $0.kind == .wrong }.map(\.message).sorted()
        if errors != wrong { return "Validation holds \(errors) of note \(id.rawValue.uuidString.prefix(4)), the pure verdict \(wrong)" }
    }
    // Everything on the board shown, not only the notes and arrows listed: what Validation keeps of the third level (what a
    // shape still needs, in its words) is exactly what the fresh check says a shape needs, after every commit.
    for record in editor.document.shapes {
        guard let freshRecord = fresh.shape(inFile: record.id) else { continue }
        let kept = editor.issues(record.id).filter { $0.severity == .incomplete }.map(\.message).sorted()
        let needs = fullCheck(of: freshRecord).problems.filter { $0.kind == .needed }.map(\.message).sorted()
        if !kept.isEmpty { needsKept += 1 }
        if kept != needs { return "Validation keeps \(kept) as what \(record.kind.rawValue) \(record.id.rawValue.uuidString.prefix(4)) still needs, the fresh check says \(needs)" }
    }
    // Both queries are asked at once: each waits a turn or two of the run loop for its answer.
    let answers = try editor.queries.map { queries in
        try awaitResult {
            async let incomplete = queries.run(QueryRequest(":incomplete", limit: QueryRequest.every, properties: .none))
            async let misfit = queries.run(QueryRequest("bond:misfit", limit: QueryRequest.every, properties: .none))
            return try await (incomplete, misfit)
        }
    }
    if let answers {
        let listed = Set(answers.0.rows.map(\.id)).intersection(notes)
        let expected = needy
        if listed != expected {
            return ":incomplete lists \(listed.map { String($0.rawValue.uuidString.prefix(4)) }.sorted()), the pure verdict \(expected.map { String($0.rawValue.uuidString.prefix(4)) }.sorted())"
        }
    }
    // And the query: `:misfit` lists exactly the arrows the verdict calls a misfit, in the whole file.
    if let answers {
        let listed = Set(answers.1.rows.map(\.id)).intersection(bonds)
        if listed != misfits {
            return ":misfit lists \(listed.map { String($0.rawValue.uuidString.prefix(4)) }.sorted()), the pure verdict \(misfits.map { String($0.rawValue.uuidString.prefix(4)) }.sorted())" }
    }
    return nil
}

/// How many steps of the runs below were made again as writes that had not committed, and held to their commit.
@MainActor private var stepsReplayed = 0
/// And how many of them brought an issue to a shape they did not write.
@MainActor private var stepsThatBroke = 0
/// How many times, over the steps, Validation kept something a shape still needs, for the agreement not to be empty.
@MainActor private var needsKept = 0

private struct Replayed: Error {}

private func word(_ issue: ValidationIssue) -> String {
    "\(issue.severity == .error ? "error" : issue.severity == .warning ? "warning" : "incomplete") \(issue.field ?? "-") \(issue.message)"
}

/// What Validation keeps of each shape on the board shown that has an issue.
@MainActor private func keptIssues(_ editor: CanvasEditor) -> [ShapeID: [String]] {
    var kept: [ShapeID: [String]] = [:]
    for record in editor.document.shapes {
        let issues = editor.issues(record.id).map(word)
        if !issues.isEmpty { kept[record.id] = issues }
    }
    return kept
}

/// The issues of `after` that `before` has not, each counted as often as it is there.
private func gained(_ before: [String], _ after: [String]) -> [String] {
    var had: [String: Int] = [:]
    for issue in before { had[issue, default: 0] += 1 }
    return after.filter { issue in
        guard let count = had[issue], count > 0 else { return true }
        had[issue] = count - 1
        return false
    }
}

/// Whether two records are one shape as a rule reads it: everything but where it is in the stack, which a shape put in
/// again takes anew.
private func same(_ a: AnyShapeRecord?, _ b: AnyShapeRecord) -> Bool {
    guard let a else { return false }
    // A record equal in everything, its place in the stack too, is one shape as a rule reads it, and says so without encoding its values.
    if a == b { return true }
    return a.id == b.id && a.kind == b.kind && a.propertiesJSON == b.propertiesJSON && a.meta == b.meta && a.container == b.container
}

/// What a run of a step's writes would say, against what the commit did: the step from `before` to the editor's file is
/// made again as writes that have not committed (a second editor on the file as it was, the board's records written in
/// one transaction that is thrown away), asked as `canvas draw` asks (the shapes Validation says the writes touch, each
/// one's issues before and after), and the shapes it would warn of, among those it does not write, must be exactly the
/// shapes the step did not write whose kept issues gained one. Nil when they are, and for a step that is not replayed:
/// one that reached another board, or whose writes a locked shape refused.
@MainActor private func runDifference(_ editor: CanvasEditor, before: CanvasFile, kept keptBefore: [ShapeID: [String]]) throws -> String? {
    let after = editor.file
    guard before.children == after.children, before.root != after.root else { return nil }
    let was = before.root, now = after.root
    let shadow = bondEditor(registry: editor.registry, file: before)
    _ = shadow.validation?.results
    let registry = shadow.registry
    var outcome: (warned: Set<ShapeID>, rewritten: Set<ShapeID>)?
    var saw: [ShapeID: String] = [:]
    try? shadow.transact { transaction in
        let gone = Set(was.shapes.map(\.id)).subtracting(now.shapes.map(\.id))
        if !gone.isEmpty { transaction.delete(gone) }
        for record in now.shapes {
            if transaction.document[record.id] == nil {
                transaction.insert(record)
            } else if !same(transaction.document[record.id], record) {
                transaction.update(record.id) { $0 = record }
            }
        }
        // The writes leave the board as the step left it, or the step is not one a run could make this way.
        guard transaction.document.shapes.count == now.shapes.count, now.shapes.allSatisfy({ same(transaction.document[$0.id], $0) }) else { throw Replayed() }
        let pending = transaction.pending, shapes = transaction.shapes
        var warned: Set<ShapeID> = []
        for id in registry.validationTouched(by: pending, in: shapes) {
            guard let record = transaction.document[id], let old = was[id] else { continue }
            let had = registry.validationIssues(of: old, in: shadow.shapeContext).map(word)
            let has = registry.validationIssues(of: record, in: shapes).map(word)
            if !gained(had, has).isEmpty { warned.insert(id); saw[id] = "run had \(had), has \(has); " + debugRows(id, record: record, shadow: shadow, shapes: shapes, editor: editor) }
        }
        // A shape the replay wrote though the step left it as it was (deleted with another and put back) is the writer's own.
        outcome = (warned, pending.shapeIDs.filter { was[$0] != nil && was[$0] == now[$0] })
        throw Replayed()
    }
    guard let outcome else { return nil }
    stepsReplayed += 1
    let keptAfter = keptIssues(editor)
    var broken: Set<ShapeID> = []
    for record in now.shapes where was[record.id] == record && !outcome.rewritten.contains(record.id) {
        if !gained(keptBefore[record.id] ?? [], keptAfter[record.id] ?? []).isEmpty { broken.insert(record.id) }
    }
    let warned = outcome.warned.subtracting(outcome.rewritten)
    if !broken.isEmpty { stepsThatBroke += 1 }
    guard warned != broken else { return nil }
    func named(_ ids: Set<ShapeID>) -> [String] {
        ids.map { id in "\(now[id]?.kind.rawValue ?? "?") \(id.rawValue.uuidString.prefix(4)): kept \(keptBefore[id] ?? []) then \(keptAfter[id] ?? []); \(saw[id] ?? "")" }.sorted()
    }
    return "a run of the step's writes would warn of \(named(warned.subtracting(broken))) which gained no issue, and say nothing of \(named(broken.subtracting(warned))) which did"
}

@MainActor private func debugRows(_ id: ShapeID, record: AnyShapeRecord, shadow: CanvasEditor, shapes: ShapeContext, editor: CanvasEditor) -> String {
    func say(_ check: FieldCheck) -> [String] { check.problems.map { "\($0.locus) \($0.message) \($0.kind)" } }
    var out = "the checks say:"
    if let checks = shadow.fieldChecks, let reading = shapes.reading { out += " run \(say(checks.check(of: record, reading: reading)))" }
    if let now = editor.document[id], let checks = editor.fieldChecks { out += " committed \(say(checks.fullCheck(of: now)))" }
    if let now = editor.document[id], let relationships = editor.relationships { out += " rows \(relationships.ruledRows(for: now[IsAProperty.self]?.map(\.shape) ?? []))" }
    return out
}

/// A drag that changes one arrow and does nothing else.
@MainActor private final class Dragged {
    let shape: ShapeID
    init(_ shape: ShapeID) { self.shape = shape }
}

extension Dragged: Session {
    var touching: Set<ShapeID> { [shape] }
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
}

/// One seeded run. With `checking` false the run makes its steps and counts what Validation keeps of what a shape still needs
/// (`needsKept`) and compares nothing: the steps of a seed come out of its generator alone, so they are the steps a checking run
/// of the same seed makes, and a count over many seeds can be made apart from the comparisons of each.
@MainActor private func agree(seed: UInt64, steps: Int, privatePills: Bool, linking: Bool, typed: Bool = false, replaying: Bool = false, checking: Bool = true) throws {
    var rng = SplitMix(state: seed)
    let editor = bondEditor(registry: try registry(typed: typed), file: CanvasFile(root: CanvasDocument()))
    var types: [ShapeID] = [], rels: [ShapeID] = [], notes: [ShapeID] = [], pills: [ShapeID] = [], bonds: [ShapeID] = []
    let pocket = ShapeID()
    editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 3000, width: 100, height: 100))))) }
    for i in 0..<3 {
        var record = slipTypeRecord(TypeSchemaProperty.starter, title: "T\(i)", at: CGPoint(x: 40, y: 40 + Double(i) * 150))
        record.meta[Open.self] = true
        editor.transact { $0.insert(record) }
        types.append(record.id)
    }
    for i in 0..<2 { rels.append(editor.addRelationshipType("R\(i)", at: CGPoint(x: 600, y: 40 + Double(i) * 150))) }
    for i in 0..<3 {
        var record = typed ? slipRecord("n\(i)", of: [types[i % 3]], at: CGPoint(x: 40 + Double(i) * 300, y: 800))
                           : instanceRecord("n\(i)", of: [types[i % 3]], at: CGPoint(x: 40 + Double(i) * 300, y: 800))
        record.meta[Open.self] = true
        editor.transact { $0.insert(record) }
        notes.append(record.id)
    }
    let heard = RelationshipHeard(editor)
    let reads = try freshReads()
    func live(_ ids: [ShapeID]) -> [ShapeID] { ids.filter { editor.shape(inFile: $0) != nil } }
    func pick<T>(_ items: [T]) -> T? { items.randomElement(using: &rng) }
    func reading() -> Reading { Reading(editor, bonds: bonds, notes: notes + types + rels, types: types + rels + notes, skippingTypes: typed) }
    var before = reading()
    var log: [String] = []
    for step in 0..<steps {
        let heardBefore = heard.changes.count
        let fileBefore = editor.file
        let keptBefore = replaying ? keptIssues(editor) : [:]
        switch Int(rng.next() % 26) {
        case 0, 1, 2:
            if let a = pick(live(types + rels + notes + pills)), let b = pick(live(types + rels + notes + pills)) {
                let of = typed && rng.next() % 3 != 0 ? pick(live(rels)).map { [$0] } ?? [] : []
                bonds.append(editor.addBond(a, b, of: of))
                log.append("bond")
            }
        case 3:
            if let type = pick(live(rels)) {
                let marked = editor.document[type]?[RelationshipProperty.self] == true
                editor.transact { $0.update(type) { $0[RelationshipProperty.self] = marked ? nil : true } }
                log.append("flip")
            }
        case 4:
            if let shape = pick(live(types + notes)) {
                if editor.types?.isType(shape) == true { editor.removeType(shape) } else { editor.makeType(shape) }
                log.append("type")
            }
        case 5:
            if let shape = pick(live(types + rels + notes + pills + bonds)) { editor.transact { $0.delete([shape]) }; log.append("delete") }
        case 24:
            // A relationship type, with its end arrows in the step (but a locked one).
            if let type = pick(live(rels)) { editor.transact("Delete") { $0.delete([type]) }; log.append("delete type") }
        case 25:
            if typed, let bond = pick(live(bonds)) {
                editor.freeze([bond], editor.document[bond]?[Frozen.self] != true)
                log.append("lock")
            }
        case 6:
            if let shape = pick(live(types + notes)) {
                if !privatePills { editor.open(shape) }
                pills.append(editor.addRelay(standingFor: [shape], says: "p", at: CGPoint(x: 40 + Double(pills.count) * 120, y: 1200)))
                log.append("pill")
            }
        case 7:
            if let pill = pick(live(pills)), let shape = pick(live(types + notes)) {
                if !privatePills { editor.open(shape) }
                editor.transact { $0.update(pill, as: Relay.self) { $0.props.stands = [Citation(shape)] } }
                log.append("repoint")
            }
        case 8:
            if privatePills, let shape = pick(live(types + notes)) {
                let open = editor.document[shape]?.meta[Open.self] == true
                editor.transact { $0.update(shape) { $0.meta[Open.self] = open ? nil : true } }
                log.append("open")
            }
        case 9, 10: editor.undo(); log.append("undo")
        case 11: editor.redo(); log.append("redo")
        case 12:
            if let bond = pick(live(bonds)), let end = pick(live(types + rels + notes + pills)) {
                editor.transact { $0.update(bond, as: Bond.self) { $0.props.to = end } }
                log.append("reaim")
            }
        case 13:
            if let shape = pick(live(types + rels + notes)) { _ = editor.transact("Move") { $0.move([shape], toBoardOwnedBy: pocket) }; log.append("move") }
        case 14:
            let typed = types.filter { editor.types?.isType($0) == true }
            if linking, let a = pick(typed), let b = pick(typed), a != b { editor.addTypeLink(a, to: b); log.append("link") }
        case 16, 17, 18:
            // A rule set on an end, or taken off: the ends are whichever bonds the run has made ends.
            if let end = pick(live(bonds).filter { editor.relationships?.end($0) != nil }) {
                let rule = pick([EndRule(), EndRule(needed: true, onlyOne: false), EndRule(needed: false, onlyOne: true), EndRule(needed: true, onlyOne: true)]) ?? EndRule()
                editor.transact { $0.update(end) { $0[RelationshipEndProperty.self] = rule.isNone ? nil : rule } }
                log.append("rule")
            }
        case 19, 20, 21:
            // A relationship between two notes (or a note and a pill), of a relationship type: what a row holds.
            if typed, let a = pick(live(notes)), let b = pick(live(notes + pills)), let type = pick(live(rels)) {
                bonds.append(editor.addBond(a, b, of: [type]))
                log.append("relate")
            }
        case 22, 23:
            // A drag of an arrow's end: hovers over shapes, then the release, as the connector does it.
            if let bond = pick(live(bonds)) {
                editor.session = Dragged(bond)
                for _ in 0..<(1 + Int(rng.next() % 2)) {
                    if let over = pick(live(types + rels + notes + pills)) {
                        let start = rng.next() % 2 == 0
                        editor.transact("Hover") { $0.update(bond, as: Bond.self) { if start { $0.props.from = over } else { $0.props.to = over } } }
                    }
                }
                editor.connectionReleased(bond)
                editor.session = nil
                log.append("drag")
            }
        default:
            if typed, rng.next() % 2 == 0, let bond = pick(live(bonds)), let type = pick(live(rels)) {
                if editor.typesOf(bond).contains(type) { editor.removeTypeLink(type, from: bond) } else { editor.addTypeLink(type, to: bond) }
                log.append("retype")
            } else if let bond = pick(live(bonds)) {
                editor.transact { $0.update(bond, as: Bond.self) { $0.props.text = MentionText(plain: pick(["", "a", "b"]) ?? "") } }
                log.append("rename")
            }
        }
        if !checking {
            for record in editor.document.shapes where editor.issues(record.id).contains(where: { $0.severity == .incomplete }) { needsKept += 1 }
            continue
        }
        let after = reading()
        let told = heard.changes[heardBefore...]
        if !told.contains(where: \.everything) {
            let arrows = told.reduce(into: Set<ShapeID>()) { $0.formUnion($1.arrows) }
            let toldNotes = told.reduce(into: Set<ShapeID>()) { $0.formUnion($1.notes) }
            var layout = told.reduce(into: Set<ShapeID>()) { $0.formUnion($1.layout) }
            layout.formUnion(editor.types?.affected(by: layout) ?? [])
            let rowsTold = told.contains { $0.rows }
            let context = "seed \(seed) step \(step) after \(log.suffix(4))"
            for (id, value) in after.bonds where before.bonds[id] != nil && before.bonds[id] != value { expect(arrows.contains(id), "\(context): the end or fit of an arrow moved and it was not named") }
            for (id, value) in after.notes where before.notes[id] != nil && before.notes[id] != value { expect(toldNotes.contains(id) || arrows.contains(id), "\(context): the relations of a note moved and it was not named") }
            for (id, verdict) in after.verdicts where before.verdicts[id] != nil && before.verdicts[id] != verdict && before.records[id] == after.records[id] {
                expect(toldNotes.contains(id) || arrows.contains(id), "\(context): the verdict of a note's ruled rows moved with the note as it was, and it was not named: \(before.verdicts[id] ?? "-") then \(verdict); relations \(after.notes[id] ?? "-"); arrows named \(arrows.count), notes \(toldNotes.count), steps told \(told.count); everything \(told.contains(where: \.everything))")
            }
            for (id, rows) in after.rows where before.rows[id] != nil && before.rows[id] != rows {
                if before.rows[id]?.count != rows.count { expect(layout.contains(id), "\(context): a type's row count moved and it was not laid out") } else { expect(rowsTold || layout.contains(id), "\(context): a row moved and the rows were not told") }
            }
        }
        before = after
        let read = reads.read(editor.file)
        if let difference = try difference(editor, bonds: bonds, reader: read.editor) {
            expect(false, "seed \(seed) step \(step) after \(log.suffix(10)): \(difference)")
            return
        }
        if typed, let difference = try verdictDifference(editor, bonds: bonds, notes: notes, read: read) {
            expect(false, "seed \(seed) step \(step) after \(log.suffix(10)): \(difference)")
            return
        }
        if replaying, let difference = try runDifference(editor, before: fileBefore, kept: keptBefore) {
            expect(false, "seed \(seed) step \(step) after \(log.suffix(10)): \(difference)")
            return
        }
    }
}

@MainActor let relationshipAgreementTests = Suite("The relationship index against the file", [
    test("after every edit and undo of a seeded run, with pills open, the kept ends and rows are what a fresh read of the file gives, and what moved was named") {
        for seed: UInt64 in [7, 11, 21] { try agree(seed: seed, steps: 120, privatePills: false, linking: seed == 11) }
    },
    test("the same with pills that are not admitted, which keep their arrows at the pill") {
        for seed: UInt64 in [5, 6] { try agree(seed: seed, steps: 120, privatePills: true, linking: false) }
    },
    test("the same with types that build on one another") {
        for seed: UInt64 in [31, 32, 33] { try agree(seed: seed, steps: 120, privatePills: false, linking: true) }
    },
    test("arrows of relationship types, through mark flips and their undo, lineage edits, a relationship type moved alone and moves across boards: Validation's kept issues are the pure verdict after every step, and what a run of the step's writes would warn of is what the commit broke") {
        for seed: UInt64 in [41, 42, 43, 44] { try agree(seed: seed, steps: 150, privatePills: false, linking: seed % 2 == 0, typed: true, replaying: true) }
    },
])

@MainActor let relationshipAgreementPillsTests = Suite("The relationship index against the file, pills and deletions", [
    test("the same with pills that are not admitted, which the arrows read as an orange end") {
        for seed: UInt64 in [51, 52, 53] { try agree(seed: seed, steps: 150, privatePills: true, linking: seed == 52, typed: true, replaying: true) }
    },
    test("relationship types deleted with their end arrows (a locked one stays), through undo: some arrows are left behind, and the verdict on each is the pure one after every step") {
        leftBehind = 0
        for seed: UInt64 in [61, 62, 63, 64, 65, 66] { try agree(seed: seed, steps: 150, privatePills: false, linking: seed % 2 == 0, typed: true) }
        expect(leftBehind > 0, "a run judged an arrow its relationship type was taken from")
    },
])

// The runs of rules set and cleared on ends and end labels merged and split: a note's Needed and Only one rows, what the check,
// Validation's kept issues and `:incomplete` hold of them are the pure verdict of the file read afresh after every step, and a
// verdict that moved with the note as it was was named. Thirty-eight seeds of 200 steps, in suites of their own so that they run
// at once: the first eight are also made again as runs (each step's writes, not yet committed, would warn of exactly the shapes it
// does not write whose kept issues gained one), the rest are compared alone, and what the three counts below say of the seeds
// together is held by the tests at the end of each: the replays' by the eight that make them, and Validation's by a run of all
// thirty-eight that compares nothing, since a count over seeds cannot be made across the suites a run is split into.

private let replayedRuleSeeds: [UInt64] = Array(61...68)
private let otherRuleSeeds: [UInt64] = (900..<930).map { UInt64($0) }

@MainActor private func ruleRuns(_ seeds: [UInt64]) throws {
    for seed in seeds {
        try agree(seed: seed, steps: 200, privatePills: seed % 3 == 0, linking: seed % 2 == 0, typed: true, replaying: seed < 70)
    }
}

@MainActor let relationshipRuleReplayTests = Suite("The relationship index against the file, rules replayed as runs", [
    test("rules set and cleared on ends, end labels merged and split: a note's Needed and Only one rows, what the check, Validation's kept issues and `:incomplete` hold of them are the pure verdict of the file read afresh after every step, and a verdict that moved with the note as it was was named; each step is also made again as a run") {
        stepsReplayed = 0
        stepsThatBroke = 0
        try ruleRuns(replayedRuleSeeds)
        expect(stepsReplayed > 600, "\(stepsReplayed) steps were made again as a run")
        expect(stepsThatBroke > 15, "\(stepsThatBroke) of them brought an issue to a shape they did not write")
    },
])

@MainActor let relationshipRuleFirstTests = Suite("The relationship index against the file, rules, seeds 900 to 909", [
    test("the same for seeds 900 to 909") { try ruleRuns(Array(otherRuleSeeds[0..<10])) },
])

@MainActor let relationshipRuleSecondTests = Suite("The relationship index against the file, rules, seeds 910 to 919", [
    test("the same for seeds 910 to 919") { try ruleRuns(Array(otherRuleSeeds[10..<20])) },
])

@MainActor let relationshipRuleThirdTests = Suite("The relationship index against the file, rules, seeds 920 to 929", [
    test("the same for seeds 920 to 929") { try ruleRuns(Array(otherRuleSeeds[20..<30])) },
])

@MainActor let relationshipRuleKeptTests = Suite("What Validation keeps a shape still needs, over the rules' seeds", [
    test("over all thirty-eight seeds of the rules' runs, Validation kept what a shape still needs, for the comparisons not to be empty") {
        needsKept = 0
        for seed in replayedRuleSeeds + otherRuleSeeds {
            try agree(seed: seed, steps: 200, privatePills: seed % 3 == 0, linking: seed % 2 == 0, typed: true, replaying: false, checking: false)
        }
        expect(needsKept > 15, "\(needsKept) times Validation kept what a shape still needs")
    },
])
