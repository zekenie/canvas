@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Topology
import Types
import Validation

// After any sequence of writes in one transaction (inserts, updates, deletes,
// a type marked and unmarked, an end re-aimed, a pill changed), with the graph asked at any point on the way, the
// run's graph is the graph a fresh compile of the transaction's file gives, the check of each arrow in the run is the
// committed check a moment later, and a note's relations in the run are its committed relations.

private struct Mix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private func short(_ id: ShapeID?) -> String { id.map { String($0.rawValue.uuidString.prefix(4)) } ?? "nil" }

/// A graph as a comparable text: the types, the marks, the names, the lists, and each relationship type's ends a side, as sets.
private func described(_ graph: RelationshipGraph) -> [String] {
    var lines: [String] = []
    lines.append("types \(graph.types.types.map(short).sorted())")
    lines.append("marked \(graph.types.relationshipTypes.map(short).sorted())")
    lines.append("names \(graph.types.names.map { "\(short($0.key))=\($0.value)" }.sorted())")
    lines.append("links \(graph.types.links.map { "\(short($0.key))=\($0.value.map { short($0.shape) })" }.sorted())")
    for (type, sides) in graph.ends.sides.sorted(by: { short($0.key) < short($1.key) }) {
        for side in RelationshipSide.allCases {
            let ends = sides[side].map { "\(short($0.type)) by \(short($0.carrier)) \($0.name ?? "-") \($0.rule.needed)\($0.rule.onlyOne)" }.sorted()
            lines.append("ends \(short(type)) \(side) \(ends)")
        }
    }
    for (end, rows) in graph.ends.rows.sorted(by: { short($0.key) < short($1.key) }) {
        lines.append("rows \(short(end)) \(rows.map { "\(short($0.key.type)) \($0.key.label) \($0.sides.map { "\($0)" }.sorted()) \($0.others.map(short).sorted()) \($0.carriers.map(short).sorted())" }.sorted())")
    }
    return lines
}

@MainActor private func verdict(_ check: FieldCheck) -> [String] {
    check.problems.map { "\($0.kind.word) \($0.placeName ?? "-") \($0.keyword)" }.sorted()
}

@MainActor private func fuzz(seed: UInt64, holds: Set<String>, manyStands: Bool) throws -> String? {
    var rng = Mix(state: seed)
    let editor = try bondEditor()
    var shapes: [ShapeID] = []       // slips: types, relationship types, notes
    var relays: [ShapeID] = []
    var bonds: [ShapeID] = []
    var log: [String] = []
    func pick(_ ids: [ShapeID]) -> ShapeID? { ids.randomElement(using: &rng) }
    func roll(_ n: Int) -> Int { Int(rng.next() % UInt64(n)) }
    /// One write on the transaction; `live` reads the transaction's own document.
    func step(_ transaction: inout Transaction) {
        let here = transaction.document
        let liveShapes = shapes.filter { here[$0] != nil }, liveBonds = bonds.filter { here[$0] != nil }, liveRelays = relays.filter { here[$0] != nil }
        switch roll(15) {
        case 0:
            let id = ShapeID()
            var record = slipTypeRecord(TypeSchemaProperty.starter, title: "T\(shapes.count)", at: CGPoint(x: 40 + Double(shapes.count) * 30, y: 40), id: id)
            if roll(2) == 0 { record[RelationshipProperty.self] = true }
            record.meta[Open.self] = true
            transaction.insert(record)
            shapes.append(id)
            log.append("type \(short(id)) marked \(record[RelationshipProperty.self] == true)")
        case 1:
            let id = ShapeID()
            var record = slipRecord("n", of: [pick(liveShapes)].compactMap { $0 }, at: CGPoint(x: 40 + Double(shapes.count) * 30, y: 400), id: id)
            if roll(2) == 0 { record.meta[Open.self] = true }
            transaction.insert(record)
            shapes.append(id)
            log.append("note \(short(id)) of \((record[IsAProperty.self] ?? []).map { short($0.shape) })")
        case 2, 3, 4:
            let ends = liveShapes + liveRelays
            guard let from = pick(ends), let to = pick(ends) else { return }
            let id = ShapeID()
            var record = AnyShapeRecord(ShapeRecord(id: id, Bond(from: from, to: to, text: MentionText(plain: roll(2) == 0 ? "" : "row\(roll(3))"))))
            if roll(2) == 0, let type = pick(liveShapes) { record[IsAProperty.self] = [TypeLink(type)] }
            if roll(4) == 0 { record[RelationshipEndProperty.self] = EndRule(needed: true, onlyOne: roll(2) == 0) }
            transaction.insert(record)
            bonds.append(id)
            log.append("bond \(short(id)) \(short(from)) -> \(short(to)) is \((record[IsAProperty.self] ?? []).map { short($0.shape) })")
        case 5:
            guard let id = pick(liveShapes) else { return }
            transaction.update(id) { $0[RelationshipProperty.self] = $0[RelationshipProperty.self] == true ? nil : true }
            log.append("mark flipped \(short(id))")
        case 6:
            guard let id = pick(liveShapes) else { return }
            transaction.update(id) { record in
                if record[TypeSchemaProperty.self] == nil {
                    record[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
                } else {
                    record[TypeSchemaProperty.self] = nil
                    record[RelationshipProperty.self] = nil
                }
            }
            log.append("schema flipped \(short(id))")
        case 7:
            guard let id = pick(liveBonds), let to = pick(liveShapes + liveRelays) else { return }
            let fromSide = roll(2) == 0
            transaction.update(id, as: Bond.self) { if fromSide { $0.props.from = to } else { $0.props.to = to } }
            log.append("re-aimed \(short(id)) \(fromSide ? "from" : "to") \(short(to))")
        case 8:
            guard let id = pick(liveBonds) else { return }
            let name = roll(2) == 0 ? "" : "row\(roll(3))"
            transaction.update(id, as: Bond.self) { $0.props.text = MentionText(plain: name) }
            log.append("named \(short(id)) \(name)")
        case 9:
            guard let id = pick(liveBonds + liveShapes + liveRelays) else { return }
            transaction.delete([id])
            log.append("deleted \(short(id))")
        case 10:
            let id = ShapeID()
            let stands = (0..<(1 + (manyStands ? roll(2) : 0))).compactMap { _ in pick(liveShapes) }
            transaction.insert(AnyShapeRecord(ShapeRecord(id: id, Relay(CGRect(x: 40 + Double(relays.count) * 30, y: 700, width: 100, height: 32), stands: stands, says: "pill"))))
            relays.append(id)
            log.append("relay \(short(id)) for \(stands.map(short))")
        case 11:
            guard let id = pick(liveRelays) else { return }
            let stands = (0..<(manyStands ? roll(3) : roll(2))).compactMap { _ in pick(liveShapes) }
            transaction.update(id, as: Relay.self) { $0.props.stands = stands.map(Citation.init) }
            log.append("relay \(short(id)) now for \(stands.map(short))")
        case 12:
            guard let id = pick(liveShapes + liveBonds) else { return }
            let list = (0..<roll(3)).compactMap { _ in pick(liveShapes) }.filter { $0 != id }
            transaction.update(id) { $0[IsAProperty.self] = list.isEmpty ? nil : list.map(TypeLink.init) }
            log.append("list of \(short(id)) now \(list.map(short))")
        case 13:
            guard let id = pick(liveShapes) else { return }
            transaction.update(id) { $0[TitleProperty.self] = "R\(log.count)" }
            log.append("retitled \(short(id))")
        default:
            guard let id = pick(liveBonds) else { return }
            transaction.update(id) { $0[RelationshipEndProperty.self] = $0[RelationshipEndProperty.self] == nil ? EndRule(needed: false, onlyOne: true) : nil }
            log.append("rule flipped \(short(id))")
        }
    }
    // A committed file to run over, a few commits of the same writes.
    for _ in 0..<(4 + roll(10)) { editor.transact("Seed") { step(&$0) } }
    log.append("-- the run")
    var inRun: [String] = []
    var checksInRun: [ShapeID: [String]] = [:]
    var relationsInRun: [ShapeID: [String]] = [:]
    let steps = 3 + roll(14)
    editor.transact("Run") { transaction in
        guard let relationships = editor.relationships, let checks = editor.fieldChecks else { return }
        for _ in 0..<steps {
            step(&transaction)
            // Asked on the way, at some writes and not at others.
            if roll(3) == 0, let reading = transaction.shapes.reading { _ = relationships.graph(in: reading) }
        }
        guard let reading = transaction.shapes.reading else { return }
        inRun = described(relationships.graph(in: reading))
        for id in bonds { if let record = transaction.document[id] { checksInRun[id] = verdict(checks.check(of: record, reading: reading)) } }
        for id in shapes where transaction.document[id] != nil {
            relationsInRun[id] = relationships.relations(of: id, in: reading).map { "\(short($0.arrow)) \(short($0.type)) \($0.side) \($0.far.reading)" }.sorted()
        }
    }
    let fresh = try bondEditor(file: editor.file)
    let freshGraph = try require(fresh.relationships).graph
    var expected = described(freshGraph)
    // With no relationship type in the file the run keeps the committed graph (its fast path): nothing of a relationship
    // reads the types then, so only the marks, the ends and the rows are held.
    if freshGraph.types.relationshipTypes.isEmpty {
        func kept(_ lines: [String]) -> [String] { lines.filter { $0.hasPrefix("marked") || $0.hasPrefix("ends") || $0.hasPrefix("rows") } }
        expected = kept(expected)
        inRun = kept(inRun)
    }
    if !holds.contains("rows") {
        inRun = inRun.filter { !$0.hasPrefix("rows") }
        expected = expected.filter { !$0.hasPrefix("rows") }
    }
    if !holds.contains("ends") {
        inRun = inRun.filter { $0.hasPrefix("rows") }
        expected = expected.filter { $0.hasPrefix("rows") }
    }
    if inRun != expected {
        let differing = Set(inRun).symmetricDifference(expected).sorted()
        return "seed \(seed): the run's graph is not a fresh compile's.\n  differing lines (run and fresh): \(differing)\n  " + log.joined(separator: "\n  ")
    }
    let freshChecks = try require(fresh.fieldChecks), freshRelationships = try require(fresh.relationships)
    for (id, said) in checksInRun where holds.contains("check") {
        // An arrow with no list (a loose end) is no row of a run: draw makes no free end.
        guard let record = fresh.shape(inFile: id), !(record[IsAProperty.self] ?? []).isEmpty else { continue }
        let committed = verdict(freshChecks.fullCheck(of: record))
        if said != committed { return "seed \(seed): the check of \(short(id)) in the run says \(said), a fresh editor's \(committed)\n  " + log.joined(separator: "\n  ") }
    }
    for (id, said) in relationsInRun where holds.contains("relations") {
        guard fresh.shape(inFile: id) != nil, fresh.types?.isType(id) != true else { continue }
        let committed = freshRelationships.relations(of: id).map { "\(short($0.arrow)) \(short($0.type)) \($0.side) \($0.far.reading)" }.sorted()
        if said != committed { return "seed \(seed): the relations of \(short(id)) in the run are \(said), a fresh editor's \(committed)\n  " + log.joined(separator: "\n  ") }
    }
    return nil
}

@MainActor private func runs(holds: Set<String>, manyStands: Bool) throws {
    var failures: [String] = []
    var count = 0
    for seed in 1...400 {
        if let failure = try fuzz(seed: UInt64(seed), holds: holds, manyStands: manyStands) {
            count += 1
            if failures.count < 2 { failures.append(failure) }
        }
    }
    expectEqual(count, 0, "of 400 seeds; the first:\n" + failures.joined(separator: "\n\n"))
}

@MainActor let relationshipRunFuzzTests = Suite("The run's graph against a fresh compile", [
    test("400 seeded runs: the types, the marks and each relationship type's ends in the run are a fresh compile's, and each arrow's check a fresh editor's") {
        try runs(holds: ["ends", "check"], manyStands: true)
    },
    test("400 seeded runs: the rows the run's graph gives each end type are a fresh compile's") {
        try runs(holds: ["rows"], manyStands: true)
    },
    test("400 seeded runs: a note's relations in the run are a fresh editor's, every pill standing for one shape at most") {
        try runs(holds: ["relations"], manyStands: false)
    },
    test("400 seeded runs: a note's relations in the run are a fresh editor's, a pill standing for one shape or two") {
        try runs(holds: ["relations"], manyStands: true)
    },
])
