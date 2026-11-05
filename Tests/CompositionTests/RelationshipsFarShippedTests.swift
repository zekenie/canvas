import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Chrome
import Connections
import CoreGraphics
import Foundation
import LanguageModels
import Locking
import Mentions
import Publishing
import References
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import TextEditing
import Titles
import Topology
import Types
import Validation

// A relationship to a note on another board, as shipped (the far-notes part's acceptance steps 1 to 13): the root holds
// a type Person (a `name`), a type Company, a relationship type Employment (a `role` and a `since`) with Person as its
// from end (the row `employer`) and Company as its to end (the row `staff`), and a note Ann (a Person); the subboard
// Clients holds Acme (a Company, public), Borealis (a Company, private) and Bolt & Co (a Company, public). A row lists
// the notes that fit on every board, a pick on another board puts a pill beside the note (and makes a private note
// public in the same step), one Undo returns both boards byte for byte, and `canvas draw` of the same edge leaves the
// same pill in the same place.

extension CanvasEditor {
    fileprivate func farIssues(_ id: ShapeID) -> [ValidationIssue] { validation?.result(for: id)?.issues ?? [] }
}

@MainActor
private struct Clients {
    let person = ShapeID(), company = ShapeID(), employment = ShapeID(), mentorship = ShapeID(), ann = ShapeID(), clients = ShapeID()
    let acme = ShapeID(), borealis = ShapeID(), bolt = ShapeID()

    var board: BoardID { BoardID(owner: clients) }

    var file: CanvasFile {
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
            if isPublic { record[PublicProperty.self] = true }
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
            subboard(clients, "Clients", at: CGPoint(x: 700, y: 40)),
        ])
        return CanvasFile(root: root, children: [clients: CanvasDocument(shapes: [
            note(acme, "Acme", of: company, at: CGPoint(x: 0, y: 0), public: true),
            note(borealis, "Borealis", of: company, at: CGPoint(x: 400, y: 0)),
            note(bolt, "Bolt & Co", of: company, at: CGPoint(x: 800, y: 0), public: true),
        ])])
    }
}

/// The shipped editor on the Clients file, in an unshown window, on a scheduler a test advances.
@MainActor
private final class FarWorld {
    let pasteboard = NSPasteboard.withUniqueName()
    let model = ScriptedLanguageModel()
    let world = Clients()
    let h: EditorHarness
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView

    init(file: CanvasFile? = nil) throws {
        let pasteboard = self.pasteboard, model = self.model
        h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: model) }
        editor = h.editor
        (window, canvas) = windowed(editor)
        window.isReleasedWhenClosed = false
        editor.viewportDidResize(to: CGSize(width: 1600, height: 900))
        editor.replaceFile(with: file ?? world.file)
        h.scheduler.advance(by: .zero)
        // Both boards are entered once, so what each holds is laid out where the editor keeps it.
        expect(editor.showBoard(world.board))
        expect(editor.showBoard(.root))
        editor.undoHistory.seal()
    }

    func close() {
        window.close()
        pasteboard.releaseGlobally()
    }

    var rows: RowBook { editor.rowBook! }
    var rowsView: RowsView? { canvas.descendants(RowsView.self).first }
    var references: [ShapeRecord<Reference>] { editor.document.shapes.compactMap { $0.typed(as: Reference.self) } }
    var arrows: [ShapeRecord<Arrow>] { editor.document.shapes.compactMap { $0.typed(as: Arrow.self) } }
    /// The relationships: arrows of Employment or Mentorship bound at both ends.
    var relationships: [ShapeRecord<Arrow>] {
        arrows.filter { ($0[IsAProperty.self] ?? []).contains { [world.employment, world.mentorship].contains($0.shape) } }
    }
    var listed: [(title: String, detail: String?)]? { rowsView?.openList?.rows.compactMap { $0.item.map { ($0.title, $0.detail) } } }

    func bytes() throws -> Data { try BoardCodec(registry: editor.registry).encode(editor.file) }
    func clientsBytes() throws -> Data { try BoardCodec(registry: editor.registry).encode(editor.contents(of: world.board)) }

    func pills(of note: ShapeID, _ name: String) -> [ShownPill] {
        guard case .related(let pills, _)? = rows.rows(of: note).first(where: { $0.name == name })?.content else { return [] }
        return pills
    }

    /// A click on the value of a note's row: the note is selected and its editing begins in the row, and the list opens.
    func click(row name: String, of note: ShapeID) throws {
        let row = try require(rows.rows(of: note).first { $0.name == name }, "a row \(name) in \(rows.rows(of: note).map(\.name))")
        editor.selection = note
        expect(editor.beginEditing(note, at: CGPoint(x: row.valueRect.minX + 8, y: row.rect.midY)))
        h.scheduler.advance(by: .zero)
    }
}

@MainActor let relationshipsFarShippedTests = Suite("A relationship to a note on another board, shipped", [
    test("steps 1 to 6: Ann's employer row lists Acme with its board, a pick puts a pill beside Ann and an arrow into it and writes nothing on Acme's board; one Undo and Redo; Borealis says it will be made public, and a pick makes it so in the same step; Undo returns both boards byte for byte") {
        let w = try FarWorld()
        defer { w.close() }
        let editor = w.editor, world = w.world
        // Step 1.
        try w.click(row: "employer", of: world.ann)
        w.window.type("ac")
        let lines = try require(w.listed)
        expectEqual(lines.map(\.title), ["Acme"], "not `No Company notes`")
        expectEqual(lines.first?.detail, "Clients", "its board at the right, and nothing else")
        // Step 2.
        let clientsBefore = try w.clientsBytes()
        let start = try w.bytes()
        w.window.pressReturn()
        expectEqual(editor.undoHistory.undoName, "Add Relationship")
        let pill = try require(w.references.first)
        expectEqual(w.references.count, 1)
        expectEqual(pill.props.target, ReferenceTarget(id: world.acme, label: "Acme"))
        let ann = try require(editor.shapeContext.frame(of: world.ann))
        expect(pill.frame.minX >= ann.maxX, "right of Ann")
        let arrow = try require(w.relationships.first)
        expectEqual(arrow.props.start.binding?.shapeID, world.ann)
        expectEqual(arrow.props.end.binding?.shapeID, pill.id)
        expectEqual(arrow[IsAProperty.self]?.map(\.shape), [world.employment])
        expectEqual(arrow[FieldValuesProperty.self], nil)
        expect(try w.clientsBytes() == clientsBefore, "Acme's board is byte-equal to before")
        expectEqual(w.pills(of: world.ann, "employer").map(\.label), ["Acme"])
        expectEqual(editor.farIssues(arrow.id).map(\.message), [], "no issues")
        // Step 3.
        let done = try w.bytes()
        editor.endEditing()
        editor.undo()
        expect(try w.bytes() == start, "both gone")
        expectEqual(editor.board, .root, "the board shown is as it was")
        editor.redo()
        expect(try w.bytes() == done, "both back")
        // Step 4.
        editor.undo()
        try w.click(row: "employer", of: world.ann)
        w.window.type("bo")
        let two = try require(w.listed)
        expectEqual(two.map(\.title), ["Borealis", "Bolt & Co"])
        expectEqual(two.first?.detail, "Clients · will be made public")
        expectEqual(two.last?.detail, "Clients")
        expectEqual(w.rowsView?.openList?.highlighted, 0)
        let atFour = try w.bytes()
        // Step 5.
        w.window.pressReturn()
        expectEqual(editor.undoHistory.undoName, "Add Relationship")
        expectEqual(editor.file.record(world.borealis)?[PublicProperty.self], true, "made public in the step")
        expectEqual(w.references.count, 1)
        // Step 6.
        let atFive = try w.bytes()
        editor.endEditing()
        editor.undo()
        expect(try w.bytes() == atFour, "both boards byte-equal to step 4's")
        expectEqual(editor.file.record(world.borealis)?[PublicProperty.self], nil)
        editor.redo()
        expect(try w.bytes() == atFive, "Redo repeats")
    },
    test("step 7: a second relationship type to the same far note reuses Ann's pill: two arrows from Ann into the one pill") {
        let w = try FarWorld()
        defer { w.close() }
        let world = w.world
        let employer = try require(w.editor.relationships?.rows(for: [world.person], isType: false).first { $0.key.type == world.employment })
        let mentor = try require(w.editor.relationships?.rows(for: [world.person], isType: false).first { $0.key.type == world.mentorship })
        expect(w.editor.relate(world.ann, to: world.acme, in: employer) != nil)
        expect(w.editor.relate(world.ann, to: world.acme, in: mentor) != nil)
        expectEqual(w.references.count, 1, "one pill for Acme")
        expectEqual(w.relationships.count, 2)
        expect(w.relationships.allSatisfy { $0.props.end.binding?.shapeID == w.references.first?.id })
    },
    test("steps 8 and 9: a far note made private by a path with no guard is a dashed pill with its live name and one warning, healed in the commit that heals it; deleted, the pill keeps the name and the warning says it is gone; undo heals") {
        let w = try FarWorld()
        defer { w.close() }
        let editor = w.editor, world = w.world
        let employer = try require(editor.relationships?.rows(for: [world.person], isType: false).first { $0.key.type == world.employment })
        let arrow = try require(editor.relate(world.ann, to: world.borealis, in: employer))
        expectEqual(editor.farIssues(arrow).map(\.message), [])
        editor.transact { $0.update(inFile: world.borealis) { $0[PublicProperty.self] = nil } }
        let pill = try require(w.pills(of: world.ann, "employer").first)
        expect(!pill.isLive, "dashed")
        expectEqual(pill.label, "Borealis", "the note's live name")
        let said = editor.farIssues(arrow)
        expectEqual(said.count, 1)
        expectEqual(said.first?.severity, .warning, "not red")
        expect(said.first?.message.contains("isn’t public") == true, "\(String(describing: said.first?.message))")
        editor.transact { $0.update(inFile: world.borealis) { $0[PublicProperty.self] = true } }
        expectEqual(editor.farIssues(arrow).map(\.message), [], "made public again heals")
        editor.transact(on: world.board, "Delete") { $0.delete([world.borealis]) }
        let gone = try require(w.pills(of: world.ann, "employer").first)
        expectEqual(gone.state, .gone(called: "Borealis"), "the name the pill kept")
        expect(editor.farIssues(arrow).first?.message.contains("is gone") == true, "\(editor.farIssues(arrow).map(\.message))")
        editor.undo()
        expect(editor.showBoard(.root))
        expectEqual(editor.farIssues(arrow).map(\.message), [], "undo heals")
    },
    test("steps 10 to 12: Backspace twice on Ann's pill for Acme takes the arrow and the pill, Acme stays public; from Acme's row on its own board the delete is one step on the board shown and Undo does not switch boards; a locked arrow refuses and Ann shakes") {
        let w = try FarWorld()
        defer { w.close() }
        let editor = w.editor, world = w.world
        let employer = try require(editor.relationships?.rows(for: [world.person], isType: false).first { $0.key.type == world.employment })
        let arrow = try require(editor.relate(world.ann, to: world.acme, in: employer))
        editor.undoHistory.seal()
        let related = try w.bytes()
        // Step 10.
        try w.click(row: "employer", of: world.ann)
        w.window.pressEscape()
        w.window.pressDelete()
        expectEqual(w.rowsView?.focusedPill, 0)
        w.window.pressDelete()
        expectEqual(editor.undoHistory.undoName, "Remove Relationship")
        expectEqual(w.references.count, 0)
        expectEqual(w.relationships.count, 0)
        expectEqual(editor.file.record(world.acme)?[PublicProperty.self], true, "Acme still public")
        editor.endEditing()
        editor.undo()
        expect(try w.bytes() == related, "undo restores both")
        // Step 11: on Clients, Acme's staff row reads through the pill; Backspace on Ann Lee's pill is one step on Clients.
        expect(editor.showBoard(world.board))
        let staff = try require(w.pills(of: world.acme, "staff").first)
        expectEqual(staff.label, "Ann Lee", "read through the pill, the arrow being on the root")
        try w.click(row: "staff", of: world.acme)
        w.window.pressEscape()
        w.window.pressDelete()
        w.window.pressDelete()
        expectEqual(editor.board, world.board, "the board shown is unchanged by it")
        expectEqual(editor.undoHistory.undoName, "Remove Relationship")
        expectEqual(editor.contents(of: .root).shapes.compactMap { $0.typed(as: Arrow.self) }.filter { $0[IsAProperty.self] != nil }.count, 0, "the root's arrow is gone")
        expectEqual(editor.contents(of: .root).shapes.filter { $0.kind == Reference.kind }.count, 0, "and its pill")
        editor.endEditing()
        editor.undo()
        expectEqual(editor.board, world.board, "undo does not switch boards")
        expect(try w.bytes() == related)
        // Step 12: a locked arrow.
        expect(editor.showBoard(.root))
        editor.lock([arrow])
        editor.undoHistory.seal()
        let locked = try w.bytes()
        try w.click(row: "employer", of: world.ann)
        w.window.pressEscape()
        w.window.pressDelete()
        w.window.pressDelete()
        expect(try w.bytes() == locked, "nothing changes")
    },
])

@MainActor let relationshipsFarDrawShippedTests = Suite("The app's pick and canvas draw leave the same pill in the same place", [
    test("for a title another note has too, the app's pick and `canvas draw` of the same edge put the same pill at the same spot, saying where its note is") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let world = Clients()
        let drawn = windowedBoard(), picked = windowedBoard()
        defer {
            drawn.close()
            picked.close()
        }
        // A second Acme, a plain note on the root, the same in both files.
        var twin = ShapeRecord(StickyNote(frame: CGRect(x: 40, y: 1500, width: 200, height: 200), text: MentionText(plain: "")))
        twin[TitleProperty.self] = "Acme"
        for board in [drawn, picked] {
            board.editor.replaceFile(with: world.file)
            board.editor.transact { $0.insert(AnyShapeRecord(twin)) }
        }
        let server = try startCommandServer(boards: [drawn, picked], frontmost: drawn)
        defer { server.stop() }
        let result = try canvas(server, ["draw", #"edge "Ann Lee" -> "Clients" > "Acme" is: "Employment""#, "--board", "\(drawn.number)"])
        expectEqual(result.status, 0, result.error)
        let row = try require(picked.editor.relationships?.rows(for: [world.person], isType: false).first { $0.key.type == world.employment })
        expect(picked.editor.relate(world.ann, to: world.acme, in: row) != nil)
        @MainActor func reference(_ editor: CanvasEditor) throws -> ShapeRecord<Reference> {
            try require(editor.document.shapes.compactMap { $0.typed(as: Reference.self) }.first)
        }
        let a = try reference(drawn.editor), b = try reference(picked.editor)
        expectEqual(a.props.frame, b.props.frame, "the same pill in the same place")
        _ = renderBitmap(picked.editor, size: CGSize(width: 1440, height: 900))
        let state = try require(picked.editor.service(ReferenceState.self))
        expectEqual(state.drawnPlace(of: b.id)?.text, "Clients")
        expectEqual(b.props.frame.width, ReferenceEdits.width(of: b.props, place: try require(state.drawnPlaceSteps(of: b.id))), "as wide as it is saying where Acme is")
    },
    test("step 13 and the equivalence: the app's pick and `canvas draw` of the same edge, on the same file, put a pill of the same size at the same spot with the same arrow; a draw of the edge after the pick is unchanged, and a query reads it through the pill") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let world = Clients()
        let drawn = windowedBoard(), picked = windowedBoard()
        defer {
            drawn.close()
            picked.close()
        }
        drawn.editor.replaceFile(with: world.file)
        picked.editor.replaceFile(with: world.file)
        let server = try startCommandServer(boards: [drawn, picked], frontmost: drawn)
        defer { server.stop() }
        // The script's edge.
        let result = try canvas(server, ["draw", #"edge "Ann Lee" -> "Acme" is: "Employment""#, "--board", "\(drawn.number)"])
        expectEqual(result.status, 0, result.error)
        // The app's pick.
        let row = try require(picked.editor.relationships?.rows(for: [world.person], isType: false).first { $0.key.type == world.employment })
        expect(picked.editor.relate(world.ann, to: world.acme, in: row) != nil)
        @MainActor func reference(_ editor: CanvasEditor) throws -> ShapeRecord<Reference> {
            try require(editor.document.shapes.compactMap { $0.typed(as: Reference.self) }.first)
        }
        let a = try reference(drawn.editor), b = try reference(picked.editor)
        expectEqual(a.props.frame, b.props.frame, "the same pill in the same place")
        expectEqual(a.props.target, b.props.target)
        // Acme's title is its alone, and both pills say where Acme is all the same, as wide as that.
        _ = renderBitmap(picked.editor, size: CGSize(width: 1440, height: 900))
        let state = try require(picked.editor.service(ReferenceState.self))
        let place = try require(state.drawnPlaceSteps(of: b.id), "a pill says where its note is, whether its title is its alone or not")
        expectEqual(place.map(\.name), ["Clients"])
        expectEqual(b.props.frame.width, ReferenceEdits.width(of: b.props, place: place), "as wide as it is saying where Acme is")
        expectEqual(a.props.frame.size, b.props.frame.size, "the pick and the draw leave one size")
        @MainActor func arrow(_ editor: CanvasEditor) throws -> ShapeRecord<Arrow> {
            try require(editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.first { $0[IsAProperty.self]?.map(\.shape) == [world.employment] })
        }
        let x = try arrow(drawn.editor), y = try arrow(picked.editor)
        expectEqual(x.props.start.binding?.shapeID, y.props.start.binding?.shapeID)
        expectEqual(y.props.end.binding?.shapeID, b.id)
        expectEqual(x[ChannelProperty.self], y[ChannelProperty.self], "the same channel")
        // Step 13: the script's edge, written again, is the arrow the app drew.
        let again = try canvas(server, ["draw", #"edge "Ann Lee" -> "Acme" is: "Employment""#, "--board", "\(picked.number)"])
        expectEqual(again.status, 0, again.error)
        let changes = try JSON(text: again.output)["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue }
        expectEqual(changes, ["unchanged"])
        // A query reads it through the pill.
        let asked = try canvas(server, ["query", #"arrow:ends-at("Acme")"#, "--brief", "--board", "\(picked.number)"])
        expectEqual(asked.status, 0, asked.error)
        let connection = try require(JSON(text: asked.output)["rows"]?.arrayValue?.first?["connection"])
        expectEqual(connection["via"]?["to"]?["id"], .string(b.id.description), "through the pill")
    },
])
