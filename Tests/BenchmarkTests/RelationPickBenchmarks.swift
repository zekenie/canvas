import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Foundation
import Geometry
import Locking
import Mentions
import StickyNotes
import Subboards
import TestKit
import Titles
import Types

// What picking in a relation row costs (`RelationPickBenchmarks.swift`): a relationship drawn or deleted from a row, a keystroke in
// the row's list over a hub's candidates (a typed side, an open side, and the worst case of all of them left out), and a hub's pills when the note they name is renamed or edited. Each figure is the
// design's proposal, held by a run alone on a quiet machine (`.claude/rules/benchmarks.md` has the figures). Run them alone with
// `TEST_FILTER="Relation pick benchmarks" ./build.sh bench` (release, the thread's CPU).

extension Budget {
    /// One relationship drawn from a row and deleted again (`relate`, `unrelate`: two relations read, three stamps, two notes'
    /// rows), over a board of 1,000 notes with one note holding 100 relationships, and at a hub of 1,000 relationships (the
    /// hub's row is read once, O(degree)). A proposal: 1 ms and 4 ms (the thread's CPU, release).
    static let relationshipDrawn = [100: 1.0, 1_000: 4.0]
    /// A keystroke in a row's list over 1,000 candidates and over 10,000 (the reverse row of a hub type, and an open side): the
    /// list keeps its deduplicated slot array and ranks what the last keystroke matched when this one extends it. A proposal:
    /// 2 ms and 4 ms (the thread's CPU, release).
    static let relationPickerKeystroke = [1_000: 2.0, 10_000: 4.0]
    /// A keystroke over 1,000 candidates that are all locked, private notes on another board (every one `.cannot`: the list is
    /// empty and every candidate is asked): the picker's worst case. A proposal: 2 ms (the thread's CPU, release).
    static let relationPickerWorstCase = 2.0
    /// A hub, a note shown by the pills of 1,000 rows, renamed: the rows that show it are made again (the thread's CPU, release).
    /// A proposal: 75 ms (three times a median of the pointer's `linkTargetRename`).
    static let relationLabelRename = 75.0
    /// A keystroke below that note's first line, with the same 1,000 rows: one label compare in the commit, and no row made again.
    /// A proposal: 0.2 ms (the pointer's `linkTargetEdit`).
    static let relationLabelEdit = 0.2
    /// A value typed in a note named by its values that 1,000 rows show (a rename every keystroke): the commit and the rows of
    /// the notes in view made again, as a frame makes them. 0.8 ms: measured 0.56, 0.58 and 0.56 ms with 35 notes in view (the commit 0.25 of it), the rows of all 1,000 made again 14 ms.
    static let relationValueKeystroke = 0.8
}

/// A Feature type, a Layer type and a relationship type `in` with an end drawn from each, `layers` Layer notes (named by
/// `name`) and one Feature note holding a relationship to each of the first `related` of them, and `features` more Feature
/// notes holding one to the first Layer note (a hub of rows that show one pill).
@MainActor private func pickBoard(layers: Int, related: Int, features: Int = 0, openSide: Bool = false, named: (Int) -> String = { "Layer \($0)" }) -> (document: CanvasDocument, ann: ShapeID, hub: ShapeID, rows: [ShapeID]) {
    func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
    func type(_ id: ShapeID, _ title: String, _ schema: String, at origin: CGPoint) -> AnyShapeRecord {
        var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), text: MentionText(plain: title)))
        note[TypeSchemaProperty.self] = SchemaText(schema)
        note[TitleProperty.self] = title
        return AnyShapeRecord(note)
    }
    let feature = ShapeID(), layer = ShapeID(), relation = ShapeID(), ann = ShapeID()
    var shapes: [AnyShapeRecord] = []
    shapes.append(type(feature, "Feature", FieldFixtures.wide(1).schema, at: CGPoint(x: 0, y: -1_200)))
    shapes.append(type(layer, "Layer", FieldFixtures.wide(3).schema, at: CGPoint(x: 400, y: -1_200)))
    var relationship = type(relation, "in", TypeSchemaProperty.starter, at: CGPoint(x: 800, y: -1_200))
    relationship[RelationshipProperty.self] = true
    shapes.append(relationship)
    shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: bound(feature), end: bound(relation)))))
    // An open side has no end drawn at the Layer type: the row lists any note of a kind that draws rows.
    if !openSide { shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: bound(relation), end: bound(layer))))) }
    var note = ShapeRecord(id: ann, StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: "Ann")))
    note[IsAProperty.self] = [TypeLink(feature)]
    shapes.append(AnyShapeRecord(note))
    var layerIDs: [ShapeID] = []
    for place in 0..<layers {
        var layerNote = ShapeRecord(StickyNote(frame: CGRect(x: CGFloat(place % 100) * 220, y: 400 + CGFloat(place / 100) * 220, width: 200, height: 200),
                                               text: MentionText(plain: named(place))))
        layerNote[IsAProperty.self] = [TypeLink(layer)]
        layerIDs.append(layerNote.id)
        shapes.append(AnyShapeRecord(layerNote))
    }
    for target in layerIDs.prefix(related) {
        var arrow = AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: bound(ann), end: bound(target))))
        arrow[IsAProperty.self] = [TypeLink(relation)]
        shapes.append(arrow)
    }
    var rows: [ShapeID] = []
    for place in 0..<features {
        var other = ShapeRecord(StickyNote(frame: CGRect(x: CGFloat(place % 100) * 220, y: 40_000 + CGFloat(place / 100) * 220, width: 200, height: 200), text: MentionText(plain: "F\(place)")))
        other[IsAProperty.self] = [TypeLink(feature)]
        rows.append(other.id)
        shapes.append(AnyShapeRecord(other))
        var arrow = AnyShapeRecord(ShapeRecord(id: ShapeID(), Arrow(start: bound(other.id), end: bound(layerIDs[0]))))
        arrow[IsAProperty.self] = [TypeLink(relation)]
        shapes.append(arrow)
    }
    return (CanvasDocument(shapes: shapes), ann, layerIDs.first ?? ShapeID(), rows)
}

@MainActor private func pickEditor(_ board: CanvasDocument, _ pasteboard: NSPasteboard) throws -> CanvasEditor {
    let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: board, scheduler: ManualScheduler())
    editor.viewportDidResize(to: CGSize(width: 1_400, height: 900))
    return editor
}

@MainActor let relationPickBenchmarks = Suite("Relation pick benchmarks", [
    test("a relationship drawn from a row and deleted again costs little: with 100 relationships at the note, and at a hub of 1,000") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for related in [100, 1_000] {
            let board = pickBoard(layers: related + 20, related: related)
            let editor = try pickEditor(board.document, pasteboard)
            let row = try require(editor.relationships?.rows(for: [try require(editor.document[board.ann]?[IsAProperty.self]?.first).shape], isType: false).first)
            let spare = try require(editor.document.shapes.last { $0[IsAProperty.self]?.isEmpty != false && $0.kind == StickyNote.kind }, "a Layer note with no relationship").id
            // The row of the hub is read, as a frame has it.
            _ = editor.rowBook?.rows(of: board.ann)
            var made: ShapeID?
            let drawn = median(runs: 11, onThread: true) { made = editor.relate(board.ann, to: spare, in: row) }
            let deleted = median(runs: 1, onThread: true) { if let made { editor.unrelate([made]) } }
            report(String(format: "%5d relationships at the note, one drawn %6.3f ms, deleted %6.3f ms (budget %.0f)", related, drawn, deleted, Budget.relationshipDrawn[related] ?? 0))
            if holdsToBudgets { expect(drawn < (Budget.relationshipDrawn[related] ?? 0), "a relationship drawn at \(related) took \(drawn) ms") }
        }
    },
    test("a keystroke in a row's list over 1,000 candidates and over 10,000 is a few milliseconds (the queries match more than a list holds, so each ranks the whole set)") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for candidates in [1_000, 10_000] {
            let board = pickBoard(layers: candidates, related: 0, named: { "Layer \($0 * 7919 % candidates) of the foundation" })
            let editor = try pickEditor(board.document, pasteboard)
            let row = try require(editor.relationships?.rows(for: [try require(editor.document[board.ann]?[IsAProperty.self]?.first).shape], isType: false).first)
            let picker = RelationPicker(editor: editor, owner: board.ann, row: row)
            expect((picker.held ?? 0) >= candidates, "the set is held: \(String(describing: picker.held))")
            var typed = ""
            let first = median(runs: 1, onThread: true) { picker.setQuery("lay") }
            let keystroke = median(runs: 9, prepare: { typed = typed == "layer 12" ? "layer 1" : "layer 12"; picker.setQuery(typed == "layer 12" ? "layer 1" : "layer") }, onThread: true) {
                picker.setQuery(typed)
            }
            report(String(format: "%6d candidates: the first query %6.2f ms, a keystroke %6.2f ms (budget %.0f), %d ranked", candidates, first, keystroke,
                          Budget.relationPickerKeystroke[candidates] ?? 0, picker.lastRanked))
            if holdsToBudgets { expect(keystroke < (Budget.relationPickerKeystroke[candidates] ?? 0), "a keystroke over \(candidates) candidates took \(keystroke) ms") }
        }
    },
    test("a hub shown by 1,000 rows renamed makes their rows again within a budget, a keystroke below its first line makes none, and a value typed in a note named by its values is measured") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let board = pickBoard(layers: 4, related: 0, features: 1_000)
        let editor = try pickEditor(board.document, pasteboard)
        let book = try require(editor.rowBook)
        // Every row is built and kept, as the frames that show them leave them.
        for row in board.rows { _ = book.rows(of: row) }
        #if DEBUG
        let made = book.rowsShown
        #endif
        let rename = median(runs: 5, prepare: {}, onThread: true) {
            let name = "Renamed \(Int.random(in: 0..<1_000_000))"
            editor.transact("Rename") { $0.update(board.hub, as: StickyNote.self) { $0.props.text = MentionText(plain: name) } }
            for row in board.rows { _ = book.rows(of: row) }
        }
        #if DEBUG
        expect(book.rowsShown - made >= 1_000, "the rows that show it were made again: \(book.rowsShown - made)")
        let before = book.rowsShown
        #endif
        let edit = median(runs: 9, onThread: true) {
            let below = "Renamed\nline \(Int.random(in: 0..<1_000_000))"
            editor.transact("Type") { $0.update(board.hub, as: StickyNote.self) { $0.props.text = MentionText(plain: below) } }
        }
        // The name is the first line: it changed once, on the first of those keystrokes.
        #if DEBUG
        expect(book.rowsShown - before == 0, "no row was made again by a keystroke below the first line: \(book.rowsShown - before)")
        #endif
        report(String(format: "a hub shown by 1,000 rows: renamed %6.2f ms (budget %.0f), a keystroke below its first line %6.3f ms (budget %.1f)",
                      rename, Budget.relationLabelRename, edit, Budget.relationLabelEdit))
        // A note named by its values: a value typed is a rename every keystroke, and a frame builds the rows of the notes in view,
        // not of the thousand the name reaches: the view is centered on the first features, and what a keystroke costs is the
        // commit and the rows in view made again (the rows of all 1,000 are reported beside it, as the rename above makes them).
        editor.transact("Values") { transaction in
            transaction.update(board.hub, as: StickyNote.self) { $0.props.text = MentionText(plain: "") }
            transaction.update(board.hub) { $0[FieldValuesProperty.self] = FieldValues(["order": 1, "purpose": "expose foobar"]) }
        }
        let viewport = editor.viewportSize
        editor.camera = camera(centering: CGRect(x: 0, y: 40_000, width: 1_400, height: 900), at: 1, in: viewport)
        let seen = CGRect(origin: editor.camera.origin, size: CGSize(width: viewport.width / editor.camera.zoom, height: viewport.height / editor.camera.zoom))
        let inView = Set(editor.paintOrder(in: seen).map(\.id))
        let visible = board.rows.filter(inView.contains)
        expect(visible.count > 10 && visible.count < 100, "the notes in view: \(visible.count)")
        for row in board.rows { _ = book.rows(of: row) }
        var step = 0
        let value = median(runs: 9, onThread: true) {
            step += 1
            editor.transact("Type") { $0.update(board.hub) { $0[FieldValuesProperty.self] = FieldValues(["order": 1, "purpose": .string("expose foobar \(step)")]) } }
            for row in visible { _ = book.rows(of: row) }
        }
        let every = median(runs: 9, onThread: true) {
            step += 1
            editor.transact("Type") { $0.update(board.hub) { $0[FieldValuesProperty.self] = FieldValues(["order": 1, "purpose": .string("expose foobar \(step)")]) } }
            for row in board.rows { _ = book.rows(of: row) }
        }
        report(String(format: "a value typed in a note named by its values shown by 1,000 rows, %d in view: a keystroke %6.2f ms (budget %.1f), with the rows of all 1,000 made again %6.2f",
                      visible.count, value, Budget.relationValueKeystroke, every))
        if holdsToBudgets {
            expect(value < Budget.relationValueKeystroke, "a value typed in the hub's name took \(value) ms")
            expect(rename < Budget.relationLabelRename, "the hub renamed took \(rename) ms")
            expect(edit < Budget.relationLabelEdit, "a keystroke below the first line took \(edit) ms")
        }
    },    test("a keystroke over 10,000 candidates on an open side, and over 1,000 locked private notes on another board that none can be picked from, are measured against their budgets") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        // An open side lists any note of a kind that draws rows (no instance set to narrow): every keystroke asks every candidate.
        let open = pickBoard(layers: 10_000, related: 0, openSide: true, named: { "Layer \($0 * 7919 % 10_000) of the foundation" })
        let openEditor = try pickEditor(open.document, pasteboard)
        let ann = try require(openEditor.document[open.ann]?[IsAProperty.self]?.first).shape
        let openRow = try require(openEditor.relationships?.rows(for: [ann], isType: false).first)
        expect(openRow.others.isEmpty, "the other side is open")
        let kinds = Set(openEditor.registry.kinds.filter { openEditor.registry.typeRows(of: $0) != nil })
        let picker = RelationPicker(editor: openEditor, owner: open.ann, row: openRow, kinds: kinds)
        picker.setQuery("lay")
        var typed = ""
        let keystroke = median(runs: 9, prepare: { typed = typed == "layer 12" ? "layer 1" : "layer 12"; picker.setQuery(typed == "layer 12" ? "layer 1" : "layer") }, onThread: true) {
            picker.setQuery(typed)
        }
        report(String(format: "10,000 candidates, an open side: a keystroke %6.2f ms (budget %.0f)", keystroke, Budget.relationPickerKeystroke[10_000] ?? 0))
        // The worst case: the typed side's instances are all on another board, private and locked.
        let board = pickBoard(layers: 0, related: 0)
        let sub = ShapeID()
        let root = CanvasDocument(shapes: board.document.shapes + [AnyShapeRecord(ShapeRecord(id: sub, Subboard(frame: CGRect(x: 0, y: 2_000, width: 240, height: 160))))])
        let layer = try require(root.shapes.first { $0[TitleProperty.self] == "Layer" }).id
        var far: [AnyShapeRecord] = []
        for place in 0..<1_000 {
            var note = ShapeRecord(StickyNote(frame: CGRect(x: CGFloat(place % 100) * 220, y: CGFloat(place / 100) * 220, width: 200, height: 200), text: MentionText(plain: "Locked \(place)")))
            note[IsAProperty.self] = [TypeLink(layer)]
            note[LockedProperty.self] = true
            far.append(AnyShapeRecord(note))
        }
        let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), file: CanvasFile(root: root, children: [sub: CanvasDocument(shapes: far)]), scheduler: ManualScheduler())
        editor.viewportDidResize(to: CGSize(width: 1_400, height: 900))
        let feature = try require(editor.document[board.ann]?[IsAProperty.self]?.first).shape
        let row = try require(editor.relationships?.rows(for: [feature], isType: false).first)
        let worst = RelationPicker(editor: editor, owner: board.ann, row: row)
        // The set is made again after a commit (every candidate is asked and left out), so a commit comes before each keystroke.
        worst.setQuery("lock")
        var step = 0
        let asked = median(runs: 9, prepare: { step += 1; editor.transact("Nudge") { $0.update(board.ann, as: StickyNote.self) { $0.props.text = MentionText(plain: "Ann \(step)") } } }, onThread: true) {
            worst.setQuery("locked \(step)")
        }
        report(String(format: "1,000 candidates, all locked private notes on another board: the first keystroke after a commit %6.2f ms (budget %.0f), %d listed", asked, Budget.relationPickerWorstCase, worst.choices.count))
        if holdsToBudgets {
            expect(keystroke < (Budget.relationPickerKeystroke[10_000] ?? 0), "a keystroke on an open side over 10,000 candidates took \(keystroke) ms")
            expect(asked < Budget.relationPickerWorstCase, "the worst case took \(asked) ms")
        }
    },
])
