import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import Mentions
import Publishing
import References
import Selection
import StickyNotes
import Subboards
import TestKit
import TextEditing
import Titles
import Types

// The gallery's states for picking in a relation row (slice 3c), appended to `relationStates`: board 1's steps 6 to 8 (the row
// focused and the list open with the untitled Layer note listed by its values, the arrow drawn and a pill in each note's row, the
// pick undone), and frames 5.2 and 5.3 (the list's lines for a note on another board, one of them saying it will be made public,
// and the far relationship drawn into a pill). A list is a window of its own, so it is made as its lines, as a menu is.

private let pickStage = CGSize(width: 1_180, height: 700)
private let farStage = CGSize(width: 980, height: 560)

@MainActor private func linesOf(_ list: CaretList?) -> String {
    guard let list else { return "(no list)\n" }
    var lines = list.rows.map { row -> String in
        switch row {
        case .item(let item): item.detail.map { "\(item.title)   \($0)" } ?? item.title
        case .empty(let words): "(\(words))"
        case .header(let words): words
        }
    }
    if let highlighted = list.highlighted, list.rows.indices.contains(highlighted) { lines.append("highlighted: line \(highlighted + 1)") }
    return lines.joined(separator: "\n") + "\n"
}

/// The board of board 1: Feature and Layer with the relationship type `in` between them and its ends drawn, a Feature note and a
/// Layer note with no title and no words, each holding values.
@MainActor
private func pickBoard(_ stage: GalleryStage) -> (feature: ShapeID, layer: ShapeID, featureNote: ShapeID, layerNote: ShapeID) {
    let editor = stage.editor
    let feature = editor.put(featureType, at: CGPoint(x: 40, y: 40)), layer = editor.put(layerType, at: CGPoint(x: 780, y: 40))
    let related = editor.putRelationshipType(at: CGPoint(x: 460, y: 80))
    editor.galleryArrow(feature, related)
    editor.galleryArrow(related, layer)
    let featureNote = editor.instance(of: [feature], words: "", ["purpose": "sign in with no password"], at: CGPoint(x: 40, y: 440))
    let layerNote = editor.instance(of: [layer], words: "", ["order": 1, "purpose": "expose foobar", "title": "foundation"], at: CGPoint(x: 780, y: 440))
    editor.selection = nil
    stage.look(at: .zero)
    return (feature, layer, featureNote, layerNote)
}

@MainActor
private func beginRow(_ stage: GalleryStage, _ note: ShapeID, _ name: String) throws {
    guard let row = stage.editor.rowBook?.rows(of: note).first(where: { $0.name == name }) else { throw GalleryFailure("a row `\(name)` on the note") }
    stage.editor.selection = note
    guard stage.editor.beginEditing(note, at: CGPoint(x: row.valueRect.minX + 8, y: row.rect.midY)) else { throw GalleryFailure("editing begins in the row") }
    stage.spin()
}

@MainActor
private func openList(_ stage: GalleryStage) -> CaretList? { stage.canvas.descendants(RowsView.self).first?.openList }

/// Ann, a Person, with an `employer` row to Company notes, and Clients, a subboard, holding Acme (public) and Borealis (private).
@MainActor
private func farBoard(_ stage: GalleryStage) -> (ann: ShapeID, acme: ShapeID, borealis: ShapeID, employment: ShapeID) {
    let person = rowsTypeID(84), company = rowsTypeID(85), employment = rowsTypeID(86), ann = ShapeID(), clients = ShapeID(), acme = ShapeID(), borealis = ShapeID()
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
    var board = ShapeRecord(id: clients, Subboard(frame: CGRect(x: 700, y: 440, width: 240, height: 160)))
    board[TitleProperty.self] = "Clients"
    let name = #"{"type": "object", "properties": {"name": {"type": "string"}}}"#
    let root = CanvasDocument(shapes: [
        type(person, "Person", name, at: CGPoint(x: 3_000, y: 3_000)),
        type(employment, "Employment", TypeSchemaProperty.starter, at: CGPoint(x: 3_400, y: 3_000), relationship: true),
        type(company, "Company", name, at: CGPoint(x: 3_800, y: 3_000)),
        end(person, employment, "employer"), end(employment, company, "staff"),
        note(ann, "Ann Lee", of: person, at: CGPoint(x: 80, y: 60)),
        AnyShapeRecord(board),
    ])
    stage.editor.replaceFile(with: CanvasFile(root: root, children: [clients: CanvasDocument(shapes: [
        note(acme, "Acme", of: company, at: CGPoint(x: 0, y: 0), public: true),
        note(borealis, "Borealis", of: company, at: CGPoint(x: 400, y: 0)),
    ])]))
    stage.editor.selection = nil
    stage.look(at: .zero)
    return (ann, acme, borealis, employment)
}

@MainActor
let pickStates: [GalleryState] = [
    GalleryState("Rel1-p6-list", answers: "Board 1, step 6", "a click on the Feature note's `in` value: the row is focused and a list opens under it with the Layer note, which has no title and no words, listed by its values, highlighted; never `No Layer notes`",
                 size: pickStage, isText: true) { stage in
        let board = pickBoard(stage)
        try beginRow(stage, board.featureNote, "in")
        guard let list = openList(stage), list.rows.count == 1, list.rows.first?.item?.title == "1 · expose foobar · foundation", list.highlighted == 0 else {
            throw GalleryFailure("one line, the Layer note by its values, highlighted: \(linesOf(openList(stage)))")
        }
        return .text("focused row: layer\n" + linesOf(list))
    },
    GalleryState("Rel1-p6-row", answers: "Board 1, step 6", "the Feature note while its `in` row is being picked in: the row focused, the note edited, the dashed line over the row", size: pickStage) { stage in
        let board = pickBoard(stage)
        try beginRow(stage, board.featureNote, "in")
        return .image(stage.picture())
    },
    GalleryState("Rel1-p7-picked", answers: "Board 1, step 7", "Return: one arrow from the Feature note to the Layer note, one head at the Layer, an `in` pill in the line; the Feature note's `in` row holds a pill of the Layer note's values and the Layer's `feature` row a pill of the Feature's",
                 size: pickStage) { stage in
        let board = pickBoard(stage)
        try beginRow(stage, board.featureNote, "in")
        stage.window.pressReturn()
        stage.editor.endEditing()
        stage.editor.selection = nil
        guard stage.editor.document.shapes.filter({ $0.kind == Arrow.kind && $0[IsAProperty.self] != nil }).count == 1,
              case .related(let pills, 0)? = stage.editor.rowBook?.rows(of: board.featureNote).last?.content, pills.count == 1 else {
            throw GalleryFailure("the pick drew one arrow and one pill")
        }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel1-p8-undone", answers: "Board 1, step 8", "Undo: the arrow and both pills are gone, and both rows read `add …` again", size: pickStage) { stage in
        let board = pickBoard(stage)
        try beginRow(stage, board.featureNote, "in")
        stage.window.pressReturn()
        stage.editor.endEditing()
        stage.editor.undo()
        stage.editor.selection = nil
        guard stage.editor.rowBook?.rows(of: board.featureNote).last?.content == .empty("add in"),
              stage.editor.rowBook?.rows(of: board.layerNote).last?.content == .empty("add feature") else { throw GalleryFailure("both rows are empty again") }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel5-p2-far-list", answers: "Edges 5, frames 5.2 and 5.3", "Ann's `employer` row typed in: the Company notes on the Clients board, Acme with its board and Borealis, which is private, saying it will be made public",
                 size: farStage, isText: true) { stage in
        let far = farBoard(stage)
        try beginRow(stage, far.ann, "employer")
        guard let list = openList(stage), list.rows.count == 2 else { throw GalleryFailure("both Company notes are listed: \(linesOf(openList(stage)))") }
        let lines = list.rows.compactMap { $0.item?.detail }
        guard lines.contains("Clients"), lines.contains("Clients · will be made public") else { throw GalleryFailure("the board, and the word for the private one: \(lines)") }
        return .text("focused row: employer\n" + linesOf(list))
    },
    GalleryState("Rel5-p3-far-drawn", answers: "Edges 5, frame 5.2", "the far relationship drawn: a pill for Acme right of Ann, the arrow into it, and Ann's `employer` row holding the pill; Acme is on the Clients board",
                 size: farStage) { stage in
        let far = farBoard(stage)
        try beginRow(stage, far.ann, "employer")
        stage.window.pressReturn()
        stage.editor.endEditing()
        stage.editor.selection = nil
        guard stage.editor.document.shapes.contains(where: { $0.kind == Reference.kind }),
              case .related(let pills, 0)? = stage.editor.rowBook?.rows(of: far.ann).last?.content, pills.count == 1 else {
            throw GalleryFailure("a pill beside Ann and one in her row")
        }
        return .image(stage.render(at: .zero))
    },
]
