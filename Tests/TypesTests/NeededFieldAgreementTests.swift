@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Types
import Validation

// What a shape still needs, kept by Validation, against what the check says of a file read afresh: a field its types need left
// empty, in its words, after every step of a seeded run, on the board shown and on another. Every way a value, a field or a
// type changes is a step: a value typed and cleared, a field made needed and not, a type added to a note and taken off it, a
// type no longer one and one again, a note moved to another board and back, a note deleted, an undo and a redo. A change that
// moves what a note needs and names nobody is a bug here (Validation keeps each shape's issues until told).

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

/// A ticket needs what `required` names; a yes or no never counts.
private func ticketSchema(required: [String]) -> String {
    let names = required.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"type":"object","properties":{"title":{"type":"string"},"owner":{"type":"string"},"done":{"type":"boolean"}},"required":[\#(names)]}"#
}

private let bugSchema = #"{"type":"object","properties":{"severity":{"type":"string"}},"required":["severity"]}"#

/// What a shape still needs, in words: Validation's issues of the third level.
@MainActor private func kept(_ issues: [ValidationIssue]) -> [String] {
    issues.filter { $0.severity == .incomplete }.map { "\($0.field ?? "-"): \($0.message)" }.sorted()
}

/// What the check of a file read afresh says a shape needs.
@MainActor private func needs(_ check: FieldCheck) -> [String] {
    check.problems.filter { $0.kind == .needed }.map { "\($0.placeName ?? "-"): \($0.message)" }.sorted()
}

/// How many shapes the runs found still needing something, on either board.
@MainActor private var needy = 0

@MainActor private func difference(_ editor: CanvasEditor, pocket: ShapeID) throws -> String? {
    let fresh = try typeEditor(file: editor.file, more: [PocketsPlugin()])
    let checks = try require(fresh.fieldChecks)
    _ = editor.validation?.results
    for record in editor.document.shapes {
        guard let freshRecord = fresh.shape(inFile: record.id) else { continue }
        let said = kept(editor.issues(record.id)), wanted = needs(checks.fullCheck(of: freshRecord))
        if said != wanted { return "Validation keeps \(said) of \(record.id.rawValue.uuidString.prefix(4)), the fresh check says \(wanted)" }
        if !wanted.isEmpty { needy += 1 }
        if editor.validation?.result(for: record.id)?.worst != nil, wanted.count == editor.issues(record.id).count {
            return "a shape that needs something and nothing else shows an issue: \(record.id.rawValue.uuidString.prefix(4))"
        }
    }
    // The board that is not shown: the rules over its shapes as the app has them.
    let board = editor.contents(of: BoardID(owner: pocket))
    for record in board.shapes {
        guard let freshRecord = fresh.shape(inFile: record.id) else { continue }
        let said = kept(editor.registry.validationIssues(of: record, in: editor.shapeContext.over(board), editor: editor)), wanted = needs(checks.fullCheck(of: freshRecord))
        if !wanted.isEmpty { needy += 1 }
        if said != wanted { return "the rules say \(said) of \(record.id.rawValue.uuidString.prefix(4)) on the other board, the fresh check says \(wanted)" }
    }
    return nil
}

@MainActor private func agree(seed: UInt64, steps: Int) throws {
    var rng = SplitMix(state: seed)
    let editor = try typeEditor(more: [PocketsPlugin()])
    let ticket = editor.addType(ticketSchema(required: ["title"]), title: "Ticket", at: CGPoint(x: 40, y: 40))
    let bug = editor.addType(bugSchema, title: "Bug", at: CGPoint(x: 400, y: 40))
    let plain = editor.addType(#"{"type":"object","properties":{"note":{"type":"string"}}}"#, title: "Plain", at: CGPoint(x: 760, y: 40))
    editor.addTypeLink(ticket, to: bug)
    let pocket = ShapeID()
    editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 3000, width: 100, height: 100))))) }
    var notes: [ShapeID] = []
    for i in 0..<4 {
        let note = editor.addInstance("", of: [[ticket], [bug], [plain], [ticket, plain]][i], title: "n\(i)", at: CGPoint(x: 40 + Double(i) * 300, y: 800))
        notes.append(note)
    }
    let types = [ticket, bug, plain]
    func live(_ ids: [ShapeID]) -> [ShapeID] { ids.filter { editor.shape(inFile: $0) != nil } }
    func pick<T>(_ items: [T]) -> T? { items.randomElement(using: &rng) }
    var log: [String] = []
    for step in 0..<steps {
        switch Int(rng.next() % 12) {
        case 0, 1, 2, 3:
            // A value typed, or cleared.
            if let note = pick(live(notes)) {
                var values: JSONObject = [:]
                for key in ["title", "owner", "severity", "note"] where rng.next() % 2 == 0 { values[key] = rng.next() % 4 == 0 ? "" : "x" }
                editor.setFieldValues(values, of: note)
                log.append("values")
            }
        case 4, 5:
            // A field made needed, or not.
            let required = pick([[], ["title"], ["owner"], ["title", "owner"], ["done"]]) ?? []
            editor.transact("Edit Type") { $0.update(ticket) { $0[TypeSchemaProperty.self] = SchemaText(ticketSchema(required: required)) } }
            log.append("required \(required)")
        case 6:
            // A type added to a note, or taken off.
            if let note = pick(live(notes)), let type = pick(types) {
                if editor.typesOf(note).contains(type) { editor.removeTypeLink(type, from: note) } else { editor.addTypeLink(type, to: note) }
                log.append("link")
            }
        case 7:
            // A type that is no longer one, and one again.
            if let type = pick(types) {
                if editor.types?.isType(type) == true { editor.removeType(type) } else { editor.makeType(type) }
                log.append("type")
            }
        case 8:
            // A note moved to the other board, or back.
            if let note = pick(live(notes)) {
                let there = editor.file.board(containing: note) == BoardID(owner: pocket)
                _ = editor.transact("Move") { $0.move([note], from: there ? BoardID(owner: pocket) : .root, to: there ? .root : BoardID(owner: pocket)) }
                log.append("move")
            }
        case 9:
            if let note = pick(live(notes)) { editor.transact { $0.delete([note]) }; log.append("delete") }
        case 10: editor.undo(); log.append("undo")
        default: editor.redo(); log.append("redo")
        }
        if let found = try difference(editor, pocket: pocket) {
            expect(false, "seed \(seed) step \(step) after \(log.suffix(6)): \(found)")
            return
        }
    }
}

@MainActor let neededFieldAgreementTests = Suite("What a note still needs, kept and read afresh", [
    test("after every step of a seeded run (values typed and cleared, fields made needed and not, types added, taken off, lost and made again, notes moved to another board, deleted, undone) Validation keeps what each note still needs, as a fresh read of the file says it, on both boards, and shows nothing for it") {
        needy = 0
        for seed: UInt64 in [3, 4, 5, 6, 7, 8] { try agree(seed: seed, steps: 120) }
        expect(needy > 300, "\(needy) times a shape was found still needing something")
    },
])
