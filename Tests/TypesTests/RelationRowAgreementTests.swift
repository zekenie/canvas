@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import Selection
import TestKit
import Titles
import Topology
import Types

// The row book kept by commits against a row book made afresh on the same file. After every
// step of a seeded run, every watched shape's laid-out frame (any board) and its rows as shown (the board shown) are
// what a second editor opened on the same file gives.

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

private func short(_ id: ShapeID) -> String { String(id.rawValue.uuidString.prefix(4)) }

@MainActor private func describe(_ rows: [ShownRow]) -> String {
    rows.map { row -> String in
        switch row.content {
        case .related(let pills, let more): return "\(row.name)[\(pills.map { "\($0.label)|\($0.isLive)|\($0.state)|\(Int($0.x))+\(Int($0.width))" }.joined(separator: ",")) +\(more)]@\(Int(row.rect.minY))"
        default: return "\(row.name)=\(row.content)@\(Int(row.rect.minY))"
        }
    }.joined(separator: "; ")
}

/// How the kept book differs from one made afresh from the same file; nil when it does not.
@MainActor private func bookDifference(_ editor: CanvasEditor, pocket: ShapeID, watch: [ShapeID]) throws -> String? {
    let fresh = try bondEditor(file: editor.file)
    _ = fresh.showBoard(BoardID(owner: pocket))
    _ = fresh.showBoard(.root)
    let kept = try require(editor.rowBook), made = try require(fresh.rowBook)
    for id in watch where editor.shape(inFile: id) != nil {
        let a = editor.frame(inFile: id), b = fresh.frame(inFile: id)
        if a != b { return "the frame of \(short(id)): kept \(String(describing: a)) against fresh \(String(describing: b))" }
    }
    for id in watch where editor.document[id] != nil {
        let a = kept.rows(of: id), b = made.rows(of: id)
        if a != b { return "the rows of \(short(id)): kept \(describe(a)) against fresh \(describe(b))" }
    }
    return nil
}

private let agreementSchemas = [
    #"{"type": "object", "properties": {"purpose": {"type": "string"}}}"#,
    #"{"type": "object", "properties": {"order": {"type": "number"}, "title2": {"type": "string"}}}"#,
    TypeSchemaProperty.starter,
]

@MainActor private func agree(seed: UInt64, steps: Int, privatePills: Bool, only: Set<Int>? = nil, skipping: Set<Int> = []) throws -> String? {
    var rng = SplitMix(state: seed)
    let editor = try bondEditor()
    var types: [ShapeID] = [], rels: [ShapeID] = [], notes: [ShapeID] = [], pills: [ShapeID] = [], bonds: [ShapeID] = []
    let pocket = ShapeID()
    editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 3000, width: 100, height: 100))))) }
    for i in 0..<3 {
        var record = slipTypeRecord(agreementSchemas[i], title: "T\(i)", at: CGPoint(x: 40 + Double(i) * 400, y: 40))
        if !privatePills { record.meta[Open.self] = true }
        editor.transact { $0.insert(record) }
        types.append(record.id)
    }
    for i in 0..<2 { rels.append(editor.addRelationshipType("R\(i)", at: CGPoint(x: 40 + Double(i) * 400, y: 400))) }
    for i in 0..<5 {
        var record = slipRecord("n\(i)", of: [types[i % 3]], at: CGPoint(x: 40 + Double(i) * 400, y: 800))
        if !privatePills { record.meta[Open.self] = true }
        editor.transact { $0.insert(record) }
        notes.append(record.id)
    }
    // Two notes on the pocket's board.
    for i in 0..<2 {
        let record = slipRecord("far\(i)", of: [types[i]], at: CGPoint(x: 40 + Double(i) * 400, y: 0))
        editor.transact(on: BoardID(owner: pocket), "Far") { $0.insert(record) }
        notes.append(record.id)
    }
    _ = editor.showBoard(BoardID(owner: pocket))
    _ = editor.showBoard(.root)
    func live(_ ids: [ShapeID]) -> [ShapeID] { ids.filter { editor.document[$0] != nil } }
    func pick<T>(_ items: [T]) -> T? { items.randomElement(using: &rng) }
    var log: [String] = []
    var names = 0
    for step in 0..<steps {
        var op = Int(rng.next() % 22)
        if let only, !only.contains(op) { op = 0 }
        if skipping.contains(op) { op = 20 }
        switch op {
        case 0, 1:
            if let a = pick(live(types + rels + pills)), let b = pick(live(types + rels + pills)) { bonds.append(editor.addBond(a, b, name: pick(["", "", "x", "y"]) ?? "")); log.append("end \(short(a))>\(short(b))") }
        case 2, 3, 4:
            if let a = pick(live(notes + pills)), let b = pick(live(notes + pills)), let rel = pick(live(rels)) { bonds.append(editor.addBond(a, b, of: [rel])); log.append("relate \(short(a))>\(short(b))") }
        case 5:
            if let type = pick(live(rels)) {
                let marked = editor.document[type]?[RelationshipProperty.self] == true
                editor.transact { $0.update(type) { $0[RelationshipProperty.self] = marked ? nil : true } }
                log.append("flip \(short(type))")
            }
        case 6:
            if let shape = pick(live(types)) {
                if editor.types?.isType(shape) == true { editor.removeType(shape) } else { editor.makeType(shape) }
                log.append("type \(short(shape))")
            }
        case 7:
            if let shape = pick(live(types + rels + notes + pills + bonds)) { editor.transact { $0.delete([shape]) }; log.append("delete \(short(shape))") }
        case 8:
            if let shape = pick(live(types + notes)) {
                if !privatePills { editor.open(shape) }
                pills.append(editor.addRelay(standingFor: [shape], says: "p\(pills.count)", at: CGPoint(x: 40 + Double(pills.count) * 120, y: 1600)))
                log.append("pill \(short(shape))")
            }
        case 9:
            if let pill = pick(live(pills)), let shape = pick(live(types + notes)) {
                if !privatePills { editor.open(shape) }
                editor.transact { $0.update(pill, as: Relay.self) { $0.props.stands = [Citation(shape)] } }
                log.append("repoint")
            }
        case 10:
            if privatePills, let shape = pick(live(types + notes)) {
                let open = editor.document[shape]?.meta[Open.self] == true
                editor.transact { $0.update(shape) { $0.meta[Open.self] = open ? nil : true } }
                log.append("open \(short(shape)) \(!open)")
            }
        case 11, 12: editor.undo(); log.append("undo")
        case 13: editor.redo(); log.append("redo")
        case 14:
            if let bond = pick(live(bonds)), let end = pick(live(types + rels + notes + pills)) {
                editor.transact { $0.update(bond, as: Bond.self) { $0.props.to = end } }
                log.append("reaim")
            }
        case 15:
            if let shape = pick(live(types + rels + notes)) { _ = editor.transact("Move") { $0.move([shape], toBoardOwnedBy: pocket) }; log.append("move \(short(shape))") }
        case 16:
            let typed = types.filter { editor.types?.isType($0) == true && editor.document[$0] != nil }
            if let a = pick(typed), let b = pick(typed), a != b { editor.addTypeLink(a, to: b); log.append("link \(short(a)) to \(short(b))") }
        case 17:
            if let bond = pick(live(bonds)) {
                editor.transact { $0.update(bond, as: Bond.self) { $0.props.text = MentionText(plain: pick(["", "x", "y"]) ?? "") } }
                log.append("name")
            }
        case 18:
            if let note = pick(live(notes)) {
                names += 1
                let words = "\(pick(["zz", "aa", "mm"]) ?? "")\(names) renamed"
                editor.transact("Rename") { $0.update(note, as: RowSlip.self) { $0.props.text = MentionText(plain: words) } }
                log.append("rename \(short(note))")
            }
        case 19:
            if let type = pick(live(types + rels)) {
                names += 1
                editor.transact("Title") { $0.update(type) { $0[TitleProperty.self] = "N\(names)" } }
                log.append("title \(short(type))")
            }
        case 20:
            if let note = pick(live(notes)) { editor.transact("Move") { $0.translate([note], by: CGPoint(x: 10, y: 5)) }; log.append("drag") }
        default:
            if let note = pick(live(notes)), let type = pick(live(types)) {
                editor.transact("Is") { $0.update(note) { $0[IsAProperty.self] = [TypeLink(type)] } }
                log.append("is \(short(note)) \(short(type))")
            }
        }
        if editor.board != .root { _ = editor.showBoard(.root) }
        if let difference = try bookDifference(editor, pocket: pocket, watch: types + rels + notes) {
            return "seed \(seed) step \(step) after \(log.suffix(8)): \(difference)"
        }
    }
    return nil
}

@MainActor let relationAgreementTests = Suite("relation rows kept against the file", [
    test("after every edit and undo of a seeded run, pills open, kept frames and rows are a fresh editor's") {
        var failures: [String] = []
        for seed: UInt64 in 1...12 { if let failure = try agree(seed: seed, steps: 100, privatePills: false) { failures.append(failure) } }
        for failure in failures { expect(false, failure) }
    },
    test("the same with pills that are not admitted") {
        var failures: [String] = []
        for seed: UInt64 in 101...108 { if let failure = try agree(seed: seed, steps: 100, privatePills: true) { failures.append(failure) } }
        for failure in failures { expect(false, failure) }
    },
    test("the same, ends, lineage, marks and lists only, no type deleted or un-typed") {
        var failures: [String] = []
        for seed: UInt64 in 201...230 { if let failure = try agree(seed: seed, steps: 120, privatePills: false, only: [0, 1, 2, 5, 11, 12, 13, 14, 16, 17, 19, 21]) { failures.append(failure) } }
        for failure in failures { expect(false, failure) }
    },
    test("the same, with types deleted and un-typed among ends and lineage") {
        var failures: [String] = []
        for seed: UInt64 in 301...330 { if let failure = try agree(seed: seed, steps: 120, privatePills: false, only: [0, 1, 2, 6, 7, 11, 12, 13, 16, 21]) { failures.append(failure) } }
        for failure in failures { expect(false, failure) }
    },
    test("the same with pills that are not admitted and never re-pointed") {
        var failures: [String] = []
        for seed: UInt64 in 101...116 { if let failure = try agree(seed: seed, steps: 100, privatePills: true, skipping: [9]) { failures.append(failure) } }
        for failure in failures { expect(false, failure) }
    },
])

private struct FreshReadFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@MainActor private func pillsOf(_ s: RelationScene, _ id: ShapeID, _ name: String) throws -> (pills: [ShownPill], more: Int) {
    guard case .related(let pills, let more) = try s.row(id, name).content else { throw FreshReadFailure("pills in \(name): \(try s.row(id, name).content)") }
    return (pills, more)
}

/// The rows a second editor opened on the same file shows for a shape on the root.
@MainActor private func freshRows(_ s: RelationScene, _ id: ShapeID) throws -> [ShownRow] {
    let fresh = try bondEditor(file: s.editor.file)
    _ = fresh.showBoard(BoardID(owner: s.pocket))
    _ = fresh.showBoard(.root)
    return try require(fresh.rowBook).rows(of: id)
}

@MainActor let relationFreshReadTests = Suite("relation rows against a fresh read", [
    test("a far note counted in +N that is renamed to sort first is shown first: the row is what a fresh read gives") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        var layers: [ShapeID] = []
        for index in 0..<30 {
            let id = s.addLayerNote("Layer \(String(format: "%02d", index))", at: CGPoint(x: 40 + 30 * Double(index), y: 1500))
            layers.append(id)
            s.relate(s.note, id)
        }
        let (pills, more) = try pillsOf(s, s.note, "layer")
        expect(more > 0, "some are counted")
        let hidden = try require(layers.last)
        expect(!pills.contains { $0.target == hidden }, "the last by name is counted, not shown")
        s.editor.transact("Rename") { $0.update(hidden, as: RowSlip.self) { $0.props.text = MentionText(plain: "Aardvark") } }
        let kept = try pillsOf(s, s.note, "layer").pills.map(\.label)
        guard case .related(let fresh, _)? = try freshRows(s, s.note).first(where: { $0.name == "layer" })?.content else { throw FreshReadFailure("fresh pills") }
        expectEqual(kept, fresh.map(\.label), "pills sort by the name each shows")
        expectEqual(kept.first, "Aardvark")
    },
    test("a pill that may not stand for its note, re-pointed at another such note: the row that reads through it shows the note it names now") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let other = s.addLayerNote("Elsewhere")
        let relay = s.editor.addRelay(standingFor: [s.layerNote], says: "Foundation")
        s.editor.addBond(s.note, relay, of: [s.rel])
        var pill = try require(try pillsOf(s, s.note, "layer").pills.first)
        expectEqual(pill.state, .notAdmitted(s.layerNote, needs: "open"))
        s.editor.transact("Re-point") { $0.update(relay, as: Relay.self) { $0.props.stands = [Citation(other)] } }
        expectEqual(s.index.relations(of: s.note).first?.far.reading, .notAdmitted(other, needs: "open"), "the index reads the new note")
        pill = try require(try pillsOf(s, s.note, "layer").pills.first)
        expectEqual(pill.state, .notAdmitted(other, needs: "open"), "the row shows it")
        expectEqual(pill.label, "Elsewhere")
    },
    test("a pill that finds several notes, its words changed: the row that shows it says the new words; and a pill that stood for nothing given a note it may not stand for") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let query = s.editor.addRelay(standingFor: [s.layerNote, s.note], says: "every layer")
        s.editor.addBond(s.note, query, of: [s.rel])
        expectEqual(try pillsOf(s, s.note, "layer").pills.first?.label, "every layer")
        s.editor.transact("Words") { $0.update(query, as: Relay.self) { $0.props.says = "all the layers" } }
        expectEqual(s.index.relations(of: s.note).first?.far.reading, .query(called: "all the layers"), "the index reads the new words")
        expectEqual(try pillsOf(s, s.note, "layer").pills.first?.label, "all the layers", "the row shows them")
        // A pill that stands for nothing, then for a note it may not stand for.
        let third = s.editor.addSlip("Third", of: [s.feature], at: CGPoint(x: 1600, y: 500))
        let blank = s.editor.addRelay(standingFor: [], says: "", at: CGPoint(x: 400, y: 1700))
        s.editor.addBond(third, blank, of: [s.rel])
        expectEqual(try pillsOf(s, third, "layer").pills.first?.state, .empty)
        s.editor.transact("Fill") { $0.update(blank, as: Relay.self) { $0.props.stands = [Citation(s.layerNote)] } }
        expectEqual(s.index.relations(of: third).first?.far.reading, .notAdmitted(s.layerNote, needs: "open"))
        expectEqual(try pillsOf(s, third, "layer").pills.first?.state, .notAdmitted(s.layerNote, needs: "open"), "the row shows the note")
    },
    test("a far note on another board renamed there: the row on the board shown that reads it through a pill is laid out with the new name") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        s.editor.transact(on: BoardID(owner: s.pocket), "Open") { $0.update(s.awayLayer) { $0.meta[Open.self] = true } }
        let relay = s.editor.addRelay(standingFor: [s.awayLayer], says: "Down")
        s.editor.addBond(s.note, relay, of: [s.rel])
        let before = try require(try pillsOf(s, s.note, "layer").pills.first)
        expectEqual(before.label, "Down")
        s.editor.transact(on: BoardID(owner: s.pocket), "Rename") { $0.update(s.awayLayer, as: RowSlip.self) { $0.props.text = MentionText(plain: "Down in the far foundations, renamed") } }
        let after = try require(try pillsOf(s, s.note, "layer").pills.first)
        expectEqual(after.label, "Down in the far foundations, renamed")
        expect(after.width > before.width)
    },
    test("a type that builds on an end type deleted, its notes still naming it: their rows and frames are what a fresh read gives; and undone") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let task = s.editor.addSlipType(featureRowsSchema, words: "", title: "Task", at: CGPoint(x: 40, y: 2000))
        s.editor.addTypeLink(s.feature, to: task)
        let taskNote = s.editor.addSlip("A task", of: [task], at: CGPoint(x: 700, y: 2000))
        expectEqual(s.names(taskNote), ["purpose", "layer"])
        @MainActor func agrees(_ when: String) throws {
            let fresh = try bondEditor(file: s.editor.file)
            _ = fresh.showBoard(BoardID(owner: s.pocket))
            _ = fresh.showBoard(.root)
            for id in [taskNote, task, s.note, s.feature] where s.editor.document[id] != nil {
                expectEqual(s.names(id), try require(fresh.rowBook).rows(of: id).map(\.name), "\(when): rows")
                expectEqual(s.editor.frame(inFile: id), fresh.frame(inFile: id), "\(when): frame; rows \(s.names(id))")
            }
            // The index's kept rows for the list against the pure graph's, and against a fresh index's.
            expectEqual(s.index.rows(for: [task], isType: false).map(\.key), s.index.graph.rows(for: [task], isType: false).map(\.key), "\(when): the index's kept rows for the list are the graph's")
        }
        s.editor.transact("Delete") { $0.delete([task]) }
        try agrees("the type deleted")
        s.editor.undo()
        try agrees("undone")
        s.editor.removeType(task)
        try agrees("Remove Type")
        s.editor.undo()
        try agrees("Remove Type undone")
        // The list of a shape that is no type but has instances: Task stops being a type, then stops building on Feature.
        s.editor.removeType(task)
        s.editor.removeTypeLink(s.feature, from: task)
        try agrees("no type, and its list changed")
        s.editor.undo()
        try agrees("that undone")
    },
    test("the list of a shape that is no type but has instances, changed and undone: the instances are laid out both ways") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let task = s.editor.addSlipType(featureRowsSchema, words: "", title: "Task", at: CGPoint(x: 40, y: 2000))
        s.editor.addTypeLink(s.feature, to: task)
        let taskNote = s.editor.addSlip("A task", of: [task], at: CGPoint(x: 700, y: 2000))
        s.editor.removeType(task)
        var told: [TypeChange] = []
        s.editor.types?.onChange { told.append($0) }
        @MainActor func state(_ when: String) throws -> String {
            let fresh = try bondEditor(file: s.editor.file)
            let line = "\(when): rows \(s.names(taskNote)) kept height \(try s.height(taskNote)) fresh \(String(describing: fresh.frame(inFile: taskNote)?.height)); told types \(told.last.map { "\($0.types.count) lineage \($0.lineage.count) lists \($0.lists.count) membership \($0.membership.count)" } ?? "-"); relationships layout \(s.heard.last?.layout.count ?? -1) notes \(s.heard.last?.notes.contains(taskNote) ?? false)"
            expectEqual(try s.height(taskNote), fresh.frame(inFile: taskNote)?.height, line)
            return line
        }
        _ = try state("no type")
        s.editor.removeTypeLink(s.feature, from: task)
        _ = try state("its list emptied")
        s.editor.undo()
        _ = try state("undone")
        s.editor.redo()
        _ = try state("redone")
        s.editor.addTypeLink(s.feature, to: task)
        _ = try state("its list given again by hand")
    },
    test("a note pasted or duplicated mid-transaction is sized with the committed ends: its relation row and the dashed line are in its frame inside the transaction") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let copy = slipRecord("A copy", of: [s.feature], at: CGPoint(x: 1600, y: 500))
        let typeCopy = slipTypeRecord(featureRowsSchema, words: "A task", title: "Task", at: CGPoint(x: 1600, y: 40))
        var linked = typeCopy
        linked[IsAProperty.self] = [TypeLink(s.feature)]
        var inside: CGRect?, insideType: CGRect?
        s.editor.transact("Paste") { transaction in
            transaction.insert(copy)
            transaction.insert(linked)
            inside = transaction.shapes.frame(of: copy.id)
            insideType = transaction.shapes.frame(of: linked.id)
        }
        let stored = try s.stored(copy.id)
        expectEqual(inside?.height, stored + relationRowsHeight(2, rule: true), "inside the transaction")
        expectEqual(try s.height(copy.id), stored + relationRowsHeight(2, rule: true), "and after")
        // A type made in the same transaction that builds on an end type is sized with the inherited relation row inside it
        // too: the run's own graph holds its lineage.
        expectEqual(insideType?.height, try s.height(linked.id), "a type the transaction made, by the run's own graph")
    },
    test("a frame builds nothing for rows already kept, and a drag of every note lets go of none") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        var notes: [ShapeID] = []
        for index in 0..<40 { notes.append(s.editor.addSlip("F\(index)", of: [s.feature], at: CGPoint(x: 40 + 330 * Double(index % 8), y: 2000 + 160 * Double(index / 8)))) }
        for (place, note) in notes.enumerated() where place % 2 == 0 { s.relate(note, s.layerNote) }
        s.editor.viewportDidResize(to: CGSize(width: 3000, height: 3000))
        _ = renderBitmap(s.editor, size: CGSize(width: 3000, height: 3000))
        let built = s.book.rowsShown
        #if DEBUG
        let made = s.book.templatesMade
        #endif
        _ = renderBitmap(s.editor, size: CGSize(width: 3000, height: 3000))
        expectEqual(s.book.rowsShown, built, "a second frame builds no rows")
        s.editor.transact("Move") { $0.translate(Set(notes + [s.layerNote]), by: CGPoint(x: 7, y: 3)) }
        _ = renderBitmap(s.editor, size: CGSize(width: 3000, height: 3000))
        expectEqual(s.book.rowsShown, built, "a drag lets go of nothing")
        #if DEBUG
        expectEqual(s.book.templatesMade, made)
        #endif
    },
    test("a click on a pill that reads through to a note on another board goes to that note") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        s.editor.transact(on: BoardID(owner: s.pocket), "Open") { $0.update(s.awayLayer) { $0.meta[Open.self] = true } }
        let relay = s.editor.addRelay(standingFor: [s.awayLayer], says: "Down")
        s.editor.addBond(s.note, relay, of: [s.rel])
        let pill = try require(try pillsOf(s, s.note, "layer").pills.first)
        expect(pill.isLive, "it reads through to the far board: \(pill.state)")
        s.harness.click(at: try s.point(onPill: 0, of: s.note, "layer"))
        s.settle()
        expectEqual(s.editor.board, BoardID(owner: s.pocket), "the far note's board is shown")
        expectEqual(s.editor.selection, s.awayLayer)
        expect(s.editor.showBoard(.root))
    },
    test("a far note whose name says another note's name (a mention in its first line): the other renamed, the pill is laid out for the name it shows") {
        let s = try RelationScene()
        s.fromEnd()
        s.toEnd()
        let named = s.editor.addSlip("Short", at: CGPoint(x: 1600, y: 900))
        let far = s.addLayerNote("placeholder")
        s.editor.transact("Words") { $0.update(far, as: RowSlip.self) { $0.props.text = MentionText([.text("see "), .mention(named, label: "Short")]) } }
        s.relate(s.note, far)
        let before = try require(try pillsOf(s, s.note, "layer").pills.first)
        s.editor.transact("Rename") { $0.update(named, as: RowSlip.self) { $0.props.text = MentionText(plain: "A very much longer name than it had before") } }
        let after = try require(try pillsOf(s, s.note, "layer").pills.first)
        guard case .related(let fresh, _)? = try freshRows(s, s.note).first(where: { $0.name == "layer" })?.content, let made = fresh.first else { throw FreshReadFailure("fresh pills") }
        expectEqual(after.label, made.label, "label (was \(before.label))")
        expectEqual(after.width, made.width, "width (was \(before.width))")
    },
])
