import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Connections
import CoreGraphics
import Foundation
import Frames
import LanguageModels
import Locking
import Mentions
import Publishing
import References
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TableOfContents
import TestKit
import TextEditing
import Titles
import Topology
import Types
import Validation

/// The far-notes part's two-board file (as RelationshipsFarShippedTests' private one), with a third public Company.
@MainActor
private struct PickClients {
    let person = ShapeID(), company = ShapeID(), employment = ShapeID(), mentorship = ShapeID(), ann = ShapeID(), clients = ShapeID()
    let acme = ShapeID(), borealis = ShapeID(), bolt = ShapeID()
    var board: BoardID { BoardID(owner: clients) }

    func file(extra: [AnyShapeRecord] = []) -> CanvasFile {
        func type(_ id: ShapeID, _ title: String, _ schema: String, at point: CGPoint, relationship: Bool = false) -> AnyShapeRecord {
            var record = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: point, size: CGSize(width: 200, height: 200)), text: MentionText(plain: "")))
            record[TypeSchemaProperty.self] = SchemaText(schema)
            record[TitleProperty.self] = title
            if relationship { record[RelationshipProperty.self] = true }
            return AnyShapeRecord(record)
        }
        func note(_ id: ShapeID, _ title: String, of type: ShapeID, at point: CGPoint, public isPublic: Bool = false) -> AnyShapeRecord {
            var record = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: point, size: CGSize(width: 200, height: 200)), text: MentionText(plain: "")))
            record[TitleProperty.self] = title
            record[IsAProperty.self] = [TypeLink(type)]
            record[FieldValuesProperty.self] = FieldValues(["name": .string(title)])
            if !isPublic { record[PrivateProperty.self] = true }
            return AnyShapeRecord(record)
        }
        func end(_ from: ShapeID, _ to: ShapeID, _ name: String) -> AnyShapeRecord {
            func bound(_ id: ShapeID) -> ArrowTerminal { .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)) }
            return AnyShapeRecord(ShapeRecord(Arrow(start: bound(from), end: bound(to), text: MentionText(plain: name))))
        }
        func subboard(_ id: ShapeID, _ title: String, at point: CGPoint) -> AnyShapeRecord {
            var record = ShapeRecord(id: id, Subboard(frame: CGRect(origin: point, size: CGSize(width: 240, height: 160))))
            record[TitleProperty.self] = title
            return AnyShapeRecord(record)
        }
        let name = #"{"type": "object", "properties": {"name": {"type": "string"}}}"#
        let job = #"{"type": "object", "properties": {"role": {"type": "string"}, "since": {"type": "string"}}}"#
        let root = CanvasDocument(shapes: [
            type(person, "Person", name, at: CGPoint(x: 40, y: 900)),
            type(employment, "Employment", job, at: CGPoint(x: 700, y: 900), relationship: true),
            type(company, "Company", name, at: CGPoint(x: 1400, y: 900)),
            type(mentorship, "Mentorship", job, at: CGPoint(x: 700, y: 1300), relationship: true),
            end(person, employment, "employer"), end(employment, company, "staff"),
            end(person, mentorship, "mentor"), end(mentorship, company, "mentee"),
            note(ann, "Ann Lee", of: person, at: CGPoint(x: 40, y: 40)),
            subboard(clients, "Clients", at: CGPoint(x: 700, y: 400)),
        ] + extra)
        return CanvasFile(root: root, children: [clients: CanvasDocument(shapes: [
            note(acme, "Acme", of: company, at: CGPoint(x: 0, y: 0), public: true),
            note(borealis, "Borealis", of: company, at: CGPoint(x: 400, y: 0)),
            note(bolt, "Bolt & Co", of: company, at: CGPoint(x: 800, y: 0), public: true),
        ])])
    }
}

@MainActor
private final class PickWorld {
    let pasteboard = NSPasteboard.withUniqueName()
    let model = ScriptedLanguageModel()
    let world = PickClients()
    let h: EditorHarness
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView

    init(extra: [AnyShapeRecord] = [], entering: Bool = true) throws {
        let pasteboard = self.pasteboard, model = self.model
        h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: model) }
        editor = h.editor
        (window, canvas) = windowed(editor)
        window.isReleasedWhenClosed = false
        editor.viewportDidResize(to: CGSize(width: 1600, height: 900))
        editor.replaceFile(with: world.file(extra: extra))
        h.scheduler.advance(by: .zero)
        if entering {
            expect(editor.showBoard(world.board))
            expect(editor.showBoard(.root))
        }
        editor.undoHistory.seal()
    }

    func close() {
        window.close()
        pasteboard.releaseGlobally()
    }

    var rows: RowBook { editor.rowBook! }
    var rowsView: RowsView? { canvas.descendants(RowsView.self).first }
    var references: [ShapeRecord<Reference>] { editor.document.shapes.compactMap { $0.typed(as: Reference.self) } }
    var relationships: [ShapeRecord<Arrow>] {
        editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.filter { ($0[IsAProperty.self] ?? []).contains { [world.employment, world.mentorship].contains($0.shape) } }
    }
    var listed: [String]? { rowsView?.openList?.rows.compactMap { $0.item?.title } }
    func bytes() throws -> Data { try BoardCodec(registry: editor.registry).encode(editor.file) }
    func row(_ type: ShapeID) throws -> RelationshipRow {
        try require(editor.relationships?.rows(for: [world.person], isType: false).first { $0.key.type == type })
    }

    func click(row name: String, of note: ShapeID) throws {
        let row = try require(rows.rows(of: note).first { $0.name == name }, "a row \(name) in \(rows.rows(of: note).map(\.name))")
        editor.selection = note
        expect(editor.beginEditing(note, at: CGPoint(x: row.valueRect.minX + 8, y: row.rect.midY)))
        h.scheduler.advance(by: .zero)
    }
}

@MainActor let relationshipPickEdgeShippedTests = Suite("A row's list and picks on the shipped list, at their edges", [
    test("Space pressed in the open list, then the note's letters: the list still lists the note, never `No matches`") {
        let m = try Minute()
        defer { m.close() }
        _ = try m.nameTheType()
        expect(try m.click(row: "in", of: m.featureNote))
        expectEqual(m.listed, ["1 · expose foobar · foundation"])
        m.window.press(" ", code: 49)
        expectEqual(m.listed, ["1 · expose foobar · foundation"], "a space typed: still the list of nothing typed")
        m.window.type("e")
        expectEqual(m.listed, ["1 · expose foobar · foundation"], "` e`: \(String(describing: m.rowsView?.openList?.rows.first))")
        m.window.type("xp")
        expectEqual(m.listed, ["1 · expose foobar · foundation"], "` exp`: \(String(describing: m.rowsView?.openList?.rows.first))")
    },
    test("a real click (the select tool's press and release) on the value of the Feature note's layer row begins editing in the row and opens the list") {
        let m = try Minute()
        defer { m.close() }
        _ = try m.nameTheType()
        let row = try require(m.rows.rows(of: m.featureNote).first { $0.name == "in" })
        m.h.click(at: m.h.view(CGPoint(x: row.valueRect.minX + 8, y: row.rect.midY)))
        m.h.scheduler.advance(by: .zero)
        expectEqual(m.editor.selection, m.featureNote)
        expectEqual(m.editor.editingShapeID, m.featureNote)
        expectEqual(m.listed, ["1 · expose foobar · foundation"])
    },
    test("two Return picks in one editing session are two steps, and Undo while the row is still focused takes one at a time, exactly") {
        let w = try PickWorld()
        defer { w.close() }
        let world = w.world
        let start = try w.bytes(), startFile = w.editor.file
        try w.click(row: "employer", of: world.ann)
        w.window.type("ac")
        w.window.pressReturn()
        expectEqual(w.relationships.count, 1)
        let one = try w.bytes(), oneFile = w.editor.file
        w.window.type("bol")
        expectEqual(w.listed?.first, "Bolt & Co")
        w.window.pressReturn()
        expectEqual(w.relationships.count, 2)
        expectEqual(w.references.count, 2)
        expectEqual(w.editor.undoHistory.undoName, "Add Relationship")
        w.editor.undo()
        expect(try w.bytes() == one && w.editor.file == oneFile, "the second pick undone alone: \(w.relationships.count) relationships, \(w.references.count) pills")
        w.editor.undo()
        expect(try w.bytes() == start && w.editor.file == startFile, "the first: \(w.relationships.count) relationships, \(w.references.count) pills")
    },
    test("Backspace and Delete on a focused relation row with no pill, and with the list open on nothing typed, never reach the canvas: the note being edited stays") {
        let m = try Minute()
        defer { m.close() }
        _ = try m.nameTheType()
        let before = m.editor.document
        expect(try m.click(row: "in", of: m.featureNote))
        m.window.pressDelete()                      // closes the list
        expect(m.rowsView?.openList == nil)
        m.window.pressDelete()                      // on the row, no pill
        m.window.press("\u{F728}", code: 117)        // forward delete
        m.window.press("\u{7f}", code: 51, modifiers: .command)
        expect(m.editor.document[m.featureNote] != nil, "the note being edited was deleted")
        expectEqual(m.editor.document, before)
        expectEqual(m.editor.editingShapeID, m.featureNote)
    },
    test("a value typed in a note named by its values renames the pill in the row that shows it, and the list's line") {
        let m = try Minute()
        defer { m.close() }
        _ = try m.nameTheType()
        let row = try require(m.editor.relationships?.rows(for: [m.feature], isType: false).first)
        expect(m.editor.relate(m.featureNote, to: m.layerNote, in: row) != nil)
        expectEqual(try m.pills(of: m.featureNote, "in").first?.label, "1 · expose foobar · foundation")
        m.editor.transact("Change Purpose") { $0.update(m.layerNote) { $0[FieldValuesProperty.self] = FieldValues(["order": 2, "purpose": "stream", "title": "foundation"]) } }
        expectEqual(try m.pills(of: m.featureNote, "in").first?.label, "2 · stream · foundation", "the pill follows the value")
        m.editor.undo()
        expectEqual(try m.pills(of: m.featureNote, "in").first?.label, "1 · expose foobar · foundation", "and its undo")
    },
    test("the app's picks and `canvas draw` of the same two edges leave the same two pills at the same rects (the second joins the column)") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let world = PickClients()
        let drawn = windowedBoard(), picked = windowedBoard()
        defer {
            drawn.close()
            picked.close()
        }
        drawn.editor.replaceFile(with: world.file())
        picked.editor.replaceFile(with: world.file())
        let server = try startCommandServer(boards: [drawn, picked], frontmost: drawn)
        defer { server.stop() }
        for name in ["Acme", "Bolt & Co"] {
            let result = try canvas(server, ["draw", "edge \"Ann Lee\" -> \"\(name)\" is: \"Employment\"", "--board", "\(drawn.number)"])
            expectEqual(result.status, 0, result.error)
        }
        let row = try require(picked.editor.relationships?.rows(for: [world.person], isType: false).first { $0.key.type == world.employment })
        expect(picked.editor.relate(world.ann, to: world.acme, in: row) != nil)
        expect(picked.editor.relate(world.ann, to: world.bolt, in: row) != nil)
        @MainActor func pills(_ editor: CanvasEditor) -> [ShapeID: CGRect] {
            Dictionary(uniqueKeysWithValues: editor.document.shapes.compactMap { $0.typed(as: Reference.self) }.compactMap { pill in pill.props.target.map { ($0.id, pill.props.frame) } })
        }
        let a = pills(drawn.editor), b = pills(picked.editor)
        expectEqual(a.count, 2)
        expectEqual(b.count, 2)
        expectEqual(b[world.acme], a[world.acme], "Acme's pill")
        expectEqual(b[world.bolt], a[world.bolt], "Bolt's pill")
        // The arrows: every property but the pill's id.
        @MainActor func arrows(_ editor: CanvasEditor) -> [ShapeRecord<Arrow>] {
            editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.filter { $0[IsAProperty.self]?.map(\.shape) == [world.employment] }
        }
        let x = arrows(drawn.editor), y = arrows(picked.editor)
        expectEqual(x.count, 2)
        expectEqual(y.count, 2)
        for (one, other) in zip(x, y) {
            expectEqual(other.props.start, one.props.start, "the start")
            expectEqual(other.props.end.binding?.normalizedAnchor, one.props.end.binding?.normalizedAnchor, "the end's anchor")
            expectEqual(other.props.end.binding?.isPrecise, one.props.end.binding?.isPrecise)
            expectEqual(other.props.end.binding?.isExact, one.props.end.binding?.isExact)
            expectEqual(other.props.bend, one.props.bend, "the bend")
            expectEqual(other.props.startArrowhead, one.props.startArrowhead)
            expectEqual(other.props.endArrowhead, one.props.endArrowhead)
            expectEqual(other.props.text, one.props.text)
            expectEqual(other.props.labelPosition, one.props.labelPosition)
            expectEqual(other[ChannelProperty.self], one[ChannelProperty.self], "the channel")
            expectEqual(other[FieldValuesProperty.self], one[FieldValuesProperty.self], "the values")
        }
        // And the stacking: pills and arrows in the same order among the board's shapes.
        @MainActor func order(_ editor: CanvasEditor) -> [String] {
            editor.document.shapes.compactMap { record in
                if let pill = record.typed(as: Reference.self) { return "pill \(pill.props.target?.label ?? "")" }
                if let arrow = record.typed(as: Arrow.self), arrow[IsAProperty.self] != nil { return "arrow" }
                return nil
            }
        }
        expectEqual(order(picked.editor), order(drawn.editor), "the order in the stack")
    },
    test("a far pick when a locked frame sits where the pill would go: the pick commits clear of it, or changes nothing and opens no step") {
        var frame = ShapeRecord(Frame(frame: CGRect(x: 250, y: 0, width: 420, height: 300)))
        frame[TitleProperty.self] = "Locked"
        let w = try PickWorld(extra: [AnyShapeRecord(frame)])
        defer { w.close() }
        w.editor.lock([frame.id])
        w.editor.undoHistory.seal()
        let before = try w.bytes(), steps = w.editor.undoHistory.undoName, canUndo = w.editor.undoHistory.canUndo
        let made = w.editor.relate(w.world.ann, to: w.world.borealis, in: try w.row(w.world.employment))
        if made == nil {
            expect(try w.bytes() == before, "refused, and something changed")
            expectEqual(w.editor.undoHistory.undoName, steps)
            expectEqual(w.editor.undoHistory.canUndo, canUndo)
            expectEqual(w.editor.file.record(w.world.borealis)?[PrivateProperty.self], true, "Borealis stays private")
        } else {
            let pill = try require(w.references.first)
            expect(!pill.props.frame.intersects(frame.props.frame), "the pill \(pill.props.frame) lies in the locked frame")
            w.editor.undo()
            expect(try w.bytes() == before, "one Undo")
        }
    },
    test("the near note in a frame: the app's pick and `canvas draw` of the same edge leave the pill at the same rect, in the same container") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let world = PickClients()
        var frame = ShapeRecord(Frame(frame: CGRect(x: 0, y: 0, width: 640, height: 320)))
        frame[TitleProperty.self] = "People"
        let drawn = windowedBoard(), picked = windowedBoard()
        defer {
            drawn.close()
            picked.close()
        }
        for board in [drawn, picked] {
            board.editor.replaceFile(with: world.file(extra: [AnyShapeRecord(frame)]))
            board.editor.put([world.ann], in: frame.id)
            expectEqual(board.editor.shapeContext.container(of: world.ann), frame.id)
        }
        let server = try startCommandServer(boards: [drawn, picked], frontmost: drawn)
        defer { server.stop() }
        let result = try canvas(server, ["draw", #"edge "Ann Lee" -> "Acme" is: "Employment""#, "--board", "\(drawn.number)"])
        expectEqual(result.status, 0, result.error)
        let row = try require(picked.editor.relationships?.rows(for: [world.person], isType: false).first { $0.key.type == world.employment })
        expect(picked.editor.relate(world.ann, to: world.acme, in: row) != nil)
        @MainActor func pill(_ editor: CanvasEditor) throws -> ShapeRecord<Reference> { try require(editor.document.shapes.compactMap { $0.typed(as: Reference.self) }.first) }
        let a = try pill(drawn.editor), b = try pill(picked.editor)
        expectEqual(b.props.frame, a.props.frame, "the same place")
        expectEqual(picked.editor.shapeContext.container(of: b.id), drawn.editor.shapeContext.container(of: a.id), "the same container")
        expectEqual(picked.editor.document.index(of: b.id).map { $0 > (picked.editor.document.index(of: frame.id) ?? -1) }, drawn.editor.document.index(of: a.id).map { $0 > (drawn.editor.document.index(of: frame.id) ?? -1) }, "the same side of the frame in the stack")
    },
    test("a file opened at its root, the other board never shown: the row lists the far notes with their board, a pick of the private one puts the pill and the arrow, the far note's own row reads it, and one Undo returns the file") {
        let w = try PickWorld(entering: false)
        defer { w.close() }
        let world = w.world
        let start = try w.bytes(), startFile = w.editor.file
        try w.click(row: "employer", of: world.ann)
        let lines = w.rowsView?.openList?.rows.compactMap { $0.item.map { "\($0.title) | \($0.detail ?? "")" } } ?? []
        expectEqual(Set(lines), ["Acme | Clients", "Borealis | Clients · will be made public", "Bolt & Co | Clients"], "\(lines)")
        w.window.type("bor")
        expectEqual(w.listed, ["Borealis"])
        w.window.pressReturn()
        expectEqual(w.editor.undoHistory.undoName, "Add Relationship")
        expectEqual(w.references.count, 1)
        expectEqual(w.relationships.count, 1)
        expectEqual(w.editor.file.record(world.borealis)?[PrivateProperty.self], nil, "made public in the step")
        let arrow = try require(w.relationships.first)
        expectEqual((w.editor.validation?.result(for: arrow.id)?.issues ?? []).map(\.message), [], "no issue")
        @MainActor func labels(_ note: ShapeID, _ name: String) -> [String] {
            guard case .related(let pills, _)? = w.rows.rows(of: note).first(where: { $0.name == name })?.content else { return [] }
            return pills.map(\.label)
        }
        expectEqual(labels(world.ann, "employer"), ["Borealis"])
        w.editor.endEditing()
        // Its board shown for the first time: the far note's row reads the relationship drawn on the root.
        expect(w.editor.showBoard(world.board))
        expectEqual(labels(world.borealis, "staff"), ["Ann Lee"], "the far note's row, its board shown for the first time")
        expectEqual(labels(world.acme, "staff"), [])
        expect(w.editor.showBoard(.root))
        w.editor.undo()
        expect(try w.bytes() == start && w.editor.file == startFile, "one Undo")
    },
    test("a far private note named by its values: the list names it by them with its board, the pill a pick makes is called by them, and a value changed on its board renames the pill in the near note's row") {
        let w = try PickWorld()
        defer { w.close() }
        let world = w.world
        var record = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 400, width: 200, height: 200), text: ""))
        record[IsAProperty.self] = [TypeLink(world.company)]
        record[FieldValuesProperty.self] = FieldValues(["name": "Zeta"])
        record[PrivateProperty.self] = true                                              // a person made it private: the pick makes it public
        let zeta = record.id, inserted = AnyShapeRecord(record)
        w.editor.transact(on: world.board, "Draw") { $0.insert(inserted) }
        w.editor.undoHistory.seal()
        try w.click(row: "employer", of: world.ann)
        w.window.type("zet")
        let line = w.rowsView?.openList?.rows.compactMap { $0.item.map { "\($0.title) | \($0.detail ?? "")" } } ?? []
        expectEqual(line, ["Zeta | Clients · will be made public"])
        w.window.pressReturn()
        w.editor.endEditing()
        let pill = try require(w.references.first)
        expectEqual(pill.props.target, ReferenceTarget(id: zeta, label: "Zeta"))
        @MainActor func labels() -> [String] {
            guard case .related(let pills, _)? = w.rows.rows(of: world.ann).first(where: { $0.name == "employer" })?.content else { return [] }
            return pills.map(\.label)
        }
        expectEqual(labels(), ["Zeta"])
        w.editor.transact("Change Name") { $0.update(inFile: zeta) { $0[FieldValuesProperty.self] = FieldValues(["name": "Zeta Corp"]) } }
        expectEqual(labels(), ["Zeta Corp"], "the row's pill follows the far note's value")
        w.editor.undo()
        expectEqual(labels(), ["Zeta"])
    },
    test("a new relationship type made from a level arrow between two notes in a frame (`/is-a`, New type) lands in the frame the arrow is in, as it did before the placing treated a box of no area as the board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
        let editor = h.editor
        editor.viewportDidResize(to: CGSize(width: 1600, height: 900))
        let a = ShapeID(), b = ShapeID(), arrow = ShapeID()
        var frame = ShapeRecord(Frame(frame: CGRect(x: 0, y: 0, width: 1400, height: 900)))
        frame[TitleProperty.self] = "Team"
        func bound(_ id: ShapeID) -> ArrowTerminal { .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)) }
        let records: [AnyShapeRecord] = [
            AnyShapeRecord(frame),
            AnyShapeRecord(ShapeRecord(id: a, StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: MentionText(plain: "Ann")))),
            AnyShapeRecord(ShapeRecord(id: b, StickyNote(frame: CGRect(x: 900, y: 100, width: 200, height: 200), text: MentionText(plain: "Acme")))),
            AnyShapeRecord(ShapeRecord(id: arrow, Arrow(start: bound(a), end: bound(b)))),
        ]
        editor.transact { t in for record in records { t.insert(record) } }
        editor.put([a, b], in: frame.id)
        editor.undoHistory.seal()
        let bounds = try require(editor.shapeContext.geometry(of: arrow)?.bounds)
        let made = try require(editor.newType(named: "Employment", besides: arrow), "a relationship type beside the arrow")
        editor.endEditing()
        let box = try require(editor.shapeContext.frame(of: made))
        expectEqual(editor.shapeContext.container(of: made), frame.id, "the new type \(box) is outside the frame \(frame.props.frame) its arrow is in (the arrow's bounds: \(bounds))")
    },
    test("both types in a frame and a note in the gap between them, in the frame, with room in the frame below the note: the new relationship type lands in the frame its two types are in, as it does with nothing in the gap") {
        let m = try Minute(featureAt: CGPoint(x: 40, y: 2040), layerAt: CGPoint(x: 1000, y: 2040))
        defer { m.close() }
        // A roomy frame round both types: 900 tall, the types and the note in its top third.
        var holder = ShapeRecord(Frame(frame: CGRect(x: 0, y: 2000, width: 1300, height: 900)))
        holder[TitleProperty.self] = "Everything"
        let frame = holder.id, inserted = holder
        m.editor.transact { $0.insert(inserted) }
        let filler = ShapeID()
        let record = AnyShapeRecord(ShapeRecord(id: filler, StickyNote(frame: CGRect(x: 420, y: 2030, width: 400, height: 220), text: MentionText(plain: "In the way"))))
        m.editor.transact { $0.insert(record) }
        m.editor.put([m.feature, m.layer, filler], in: frame)
        expectEqual(m.editor.shapeContext.container(of: m.feature), frame)
        expectEqual(m.editor.shapeContext.container(of: filler), frame)
        m.editor.undoHistory.seal()
        try m.drag(from: m.feature, to: m.layer)
        let made = try require(m.editor.document.shapes.last { $0[RelationshipProperty.self] == true }).id
        let box = try m.frame(made), around = try m.frame(frame)
        for (name, id) in [("the note in the gap", filler), ("Feature", m.feature), ("Layer", m.layer)] {
            expect(!box.intersects(try m.frame(id)), "the new type \(box) overlaps \(name)")
        }
        expect(around.contains(box), "the new type \(box) is outside the frame \(around) its two types are in")
        expectEqual(m.editor.shapeContext.container(of: made), frame, "held by the frame, as the type made with nothing in the gap is")
        m.editor.closeCard()
    },
    test("a far pick from the to side (the far note's board shown): the pill for the near note's far end lands left of the note, the arrow runs from it, and it fits") {
        let w = try PickWorld()
        defer { w.close() }
        let world = w.world
        expect(w.editor.showBoard(world.board))
        w.editor.undoHistory.seal()
        let start = try w.bytes()
        let staff = try require(w.editor.relationships?.rows(for: [world.company], isType: false).first { $0.key.type == world.employment })
        let arrow = try require(w.editor.relate(world.acme, to: world.ann, in: staff), "a pick of Ann from Acme's staff row")
        let made = try require(w.editor.document[arrow]?.typed(as: Arrow.self))
        let pill = try require(w.references.first)
        expectEqual(pill.props.target?.id, world.ann)
        expectEqual(made.props.start.binding?.shapeID, pill.id, "from the pill that stands for Ann")
        expectEqual(made.props.end.binding?.shapeID, world.acme)
        expectEqual(w.editor.file.record(world.ann)?[PrivateProperty.self], nil, "Ann made public in the step")
        expectEqual((w.editor.validation?.result(for: arrow)?.issues ?? []).map(\.message), [], "no issue")
        let acme = try require(w.editor.shapeContext.frame(of: world.acme))
        expect(pill.props.frame.maxX <= acme.minX, "left of Acme: \(pill.props.frame)")
        w.editor.undo()
        expect(try w.bytes() == start, "one Undo, both boards")
        expectEqual(w.editor.board, world.board)
    },
    test("a related note moved onto the other board by a drop of its row, with no handler for the move yet: its arrow keeps its end on the pill, now free, is warned of and sits in no row, and one Undo restores it") {
        let w = try PickWorld()
        defer { w.close() }
        let world = w.world
        let arrow = try require(w.editor.relate(world.ann, to: world.acme, in: try w.row(world.employment)))
        w.editor.undoHistory.seal()
        let start = try w.bytes(), startFile = w.editor.file
        expectEqual((w.editor.validation?.result(for: arrow)?.issues ?? []).map(\.message), [])
        let contents = try require(w.editor.tableOfContents)
        expect(contents.beginDrag(from: world.ann) && contents.drop(on: ContentsDropTarget(row: world.clients, zone: .on)))
        expectEqual(w.editor.file.board(containing: world.ann), world.board, "Ann is on Clients")
        expectEqual(w.editor.board, world.board, "and the window with her")
        expectEqual(w.editor.undoHistory.undoName, "Move")
        let kept = try require(w.editor.file.record(arrow)?.typed(as: Arrow.self), "the arrow is kept")
        expect(kept.props.start.binding?.shapeID != world.ann, "its end at Ann is free: \(kept.props.start)")
        w.editor.goBack()
        expectEqual(w.editor.board, .root, "Back to the board the arrow stayed on, which is the board Validation checks")
        expect(!(w.editor.validation?.result(for: arrow)?.issues ?? []).isEmpty, "the arrow is warned of")
        expectEqual(w.rows.rows(of: world.ann).first { $0.name == "employer" }.map { row -> Int in
            if case .related(let pills, _) = row.content { pills.count } else { 0 }
        } ?? 0, 0, "and it is in no row")
        w.editor.undo()
        expect(try w.bytes() == start && w.editor.file == startFile, "one Undo restores it")
    },
    test("two related notes moved together by a drop of their rows keep the arrow between them, bound") {
        let ann = ShapeID(), zed = ShapeID(), link = ShapeID()
        func note(_ id: ShapeID, _ name: String, of type: ShapeID, at point: CGPoint) -> AnyShapeRecord {
            var record = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: point, size: CGSize(width: 200, height: 200)), text: MentionText(plain: "")))
            record[TitleProperty.self] = name
            record[IsAProperty.self] = [TypeLink(type)]
            return AnyShapeRecord(record)
        }
        func bound(_ id: ShapeID) -> ArrowTerminal { .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)) }
        let world = PickClients()
        var arrow = AnyShapeRecord(ShapeRecord(id: link, Arrow(start: bound(ann), end: bound(zed))))
        arrow[IsAProperty.self] = [TypeLink(world.employment)]
        let w = try PickWorld(extra: [note(ann, "Ann Two", of: world.person, at: CGPoint(x: 40, y: 400)), note(zed, "Zed Co", of: world.company, at: CGPoint(x: 400, y: 400)), arrow])
        defer { w.close() }
        let contents = try require(w.editor.tableOfContents)
        contents.select([ann, zed])
        w.editor.undoHistory.seal()
        expect(contents.beginDrag(from: ann) && contents.drop(on: ContentsDropTarget(row: w.world.clients, zone: .on)))
        expectEqual(w.editor.file.board(containing: ann), w.world.board)
        expectEqual(w.editor.file.board(containing: zed), w.world.board)
        expectEqual(w.editor.file.board(containing: link), w.world.board, "the arrow went with them")
        let moved = try require(w.editor.file.record(link)?.typed(as: Arrow.self)?.props)
        expectEqual(moved.start.binding?.shapeID, ann)
        expectEqual(moved.end.binding?.shapeID, zed)
    },
    test("a pill held by a pick keeps the far note public, refusing Make Private; the delete that empties it frees the note, which stays public, and Make Private works") {
        let w = try PickWorld()
        defer { w.close() }
        let world = w.world
        let arrow = try require(w.editor.relate(world.ann, to: world.acme, in: try w.row(world.employment)))
        expectEqual(w.editor.topology?.standIns(for: world.acme).count, 1, "one stands for it")
        expect(w.editor.publishing?.isHeld(world.acme) == true)
        expectEqual(w.editor.makePrivate([world.acme]), [world.acme], "refused while the pill stands for it")
        expectEqual(w.editor.file.record(world.acme)?[PrivateProperty.self], nil)
        expect(w.editor.unrelate([arrow], shaking: world.ann))
        expectEqual(w.editor.topology?.standIns(for: world.acme).count, 0, "none stands for it")
        expectEqual(w.editor.file.record(world.acme)?[PrivateProperty.self], nil, "Acme stays public")
        expect(w.editor.showBoard(world.board), "Acme's board, where Make Private reaches it")
        expectEqual(w.editor.makePrivate([world.acme]), [], "nothing holds it")
        expectEqual(w.editor.file.record(world.acme)?[PrivateProperty.self], true)
    },
])
