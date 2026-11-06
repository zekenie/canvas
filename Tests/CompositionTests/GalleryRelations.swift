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
import TestKit
import Titles
import Types

// The gallery's states for a relationship type's rows (slice 3a): the two type notes with their relation rows once an end is
// drawn (wireframe board 1, step 4), a Feature note with an empty `add layer` row under its fields and the dashed line, a note
// with two pills and `+N`, a pill in each dashed state, and the same zoomed out. Added to `galleryStates`
// (GalleryTypesLook.swift) as `relationStates`. The types sit off the stage unless they are the picture; the relationship type
// is a plain type with the mark. Slice 3b appends `releaseStates` (board 1's steps 1 to 5 and 9, and frame 3.3): the drag
// from one type to the other, the relationship type it lands as, a pill edited in place, the rows both notes gain, the name
// typed, and a drag between the notes that takes the type; the list at the arrow is its outline, as a menu is. Slice 3c appends
// `pickStates` (GalleryPicks.swift): board 1's steps 6 to 8 and the far pick's frames 5.2 and 5.3.

private let single = CGSize(width: 460, height: 380)
private let boardSize = CGSize(width: 860, height: 640)
private let manyStage = CGSize(width: 1_180, height: 600)

/// Where the types go when they are not the picture.
private let away = CGPoint(x: 3000, y: 3000)

let featureType: FieldFixtures.TypeText = (rowsTypeID(80), "Feature", "A feature in a software system, has a purpose.", fieldsSchema(["purpose"]))
let layerType: FieldFixtures.TypeText = (
    rowsTypeID(81), "Layer", "A layer in a software system, has an order, a purpose and a title.",
    #"{"type": "object", "properties": {"order": {"type": "number"}, "purpose": {"type": "string"}, "title": {"type": "string"}}}"#)
private let relationshipID = rowsTypeID(82)

extension CanvasEditor {
    /// The relationship type `in`: a type with the mark and no fields, at `origin`.
    @discardableResult
    func putRelationshipType(at origin: CGPoint) -> ShapeID {
        let id = addTypeNote(TypeSchemaProperty.starter, text: "", title: "in", frame: CGRect(origin: origin, size: CGSize(width: 200, height: 200)), id: relationshipID)
        transact("Mark") { $0.update(id) { $0[RelationshipProperty.self] = true } }
        return id
    }

    /// An arrow bound at both ends, of the relationship type if given.
    @discardableResult
    func galleryArrow(_ from: ShapeID, _ to: ShapeID, of type: ShapeID? = nil) -> ShapeID {
        func bound(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        var record = ShapeRecord(id: ShapeID(), Arrow(start: bound(from), end: bound(to), startArrowhead: false, endArrowhead: true))
        if let type { record[IsAProperty.self] = [TypeLink(type)] }
        let arrow = AnyShapeRecord(record)
        transact { $0.insert(arrow) }
        return arrow.id
    }

    /// Feature and Layer off the stage with the relationship type between them, and an end drawn at each.
    func drawnEnds() {
        put(featureType, at: away)
        put(layerType, at: CGPoint(x: away.x + 400, y: away.y))
        putRelationshipType(at: CGPoint(x: away.x + 200, y: away.y + 400))
        galleryArrow(featureType.id, relationshipID)
        galleryArrow(relationshipID, layerType.id)
    }

    /// A reference to a note, a pill that stands for it, off the stage.
    @discardableResult
    func galleryPill(for target: ShapeID, label: String, at origin: CGPoint) -> ShapeID {
        var props = Reference(frame: CGRect(origin: origin, size: Reference.defaultSize))
        ReferenceEdits.pick(&props, ReferenceTarget(id: target, label: label))
        return add(props)
    }
}

/// The row of a note, or a failure saying what the state needed.
@MainActor
private func relationRow(_ stage: GalleryStage, _ note: ShapeID, _ name: String) throws -> ShownRow {
    try stage.editor.rowBook.flatMap { $0.rows(of: note).first { $0.name == name } }.orThrow(GalleryFailure("a row `\(name)` on the note"))
}

extension Optional {
    fileprivate func orThrow(_ error: any Error) throws -> Wrapped {
        guard let self else { throw error }
        return self
    }
}

@MainActor
let relationStates: [GalleryState] = [
    GalleryState("Rel1-p4-type-notes", answers: "Board 1, step 4",
                 "a Feature type and a Layer type with a relationship type between them, an arrow into it and one out of it: each type note lists its relationship under its fields and a dashed line, `layer → Layer` and `feature ← Feature`",
                 size: boardSize) { stage in
        let editor = stage.editor
        editor.put(featureType, at: CGPoint(x: 40, y: 40))
        editor.put(layerType, at: CGPoint(x: 480, y: 40))
        editor.putRelationshipType(at: CGPoint(x: 330, y: 420))
        editor.galleryArrow(featureType.id, relationshipID)
        editor.galleryArrow(relationshipID, layerType.id)
        editor.selection = nil
        guard let book = editor.rowBook,
              book.rows(of: featureType.id).last?.content == .relationType(direction: "→", chips: [layerType.id], more: 0),
              book.rows(of: layerType.id).last?.content == .relationType(direction: "←", chips: [featureType.id], more: 0) else {
            throw GalleryFailure("each type note lists the relationship with the type at the other end")
        }
        return canvas(stage)
    },
    GalleryState("Rel1-p4-empty-rows", answers: "Board 1, step 4",
                 "a Feature note and a Layer note once the ends are drawn: their fields, the dashed line and an empty row each, `add in` and `add feature`, in faint italic",
                 size: CGSize(width: 860, height: 340)) { stage in
        let editor = stage.editor
        editor.drawnEnds()
        let feature = editor.instance(of: [featureType.id], words: "", ["purpose": "sign in with no password"], at: CGPoint(x: 40, y: 40))
        let layer = editor.instance(of: [layerType.id], words: "", ["order": 1, "purpose": "expose foobar", "title": "foundation"], at: CGPoint(x: 460, y: 40))
        editor.selection = nil
        guard try relationRow(stage, feature, "in").content == .empty("add in"), try relationRow(stage, layer, "feature").content == .empty("add feature") else {
            throw GalleryFailure("an empty row under the dashed line on each note")
        }
        return canvas(stage)
    },
    GalleryState("relations-pills", "a Feature note related to six Layer notes: two pills that fit, in name order, and `+4`", size: single) { stage in
        let editor = stage.editor
        editor.drawnEnds()
        let feature = editor.instance(of: [featureType.id], words: "Sign in", ["purpose": "sign in with no password"], at: CGPoint(x: 40, y: 40))
        for (place, name) in ["Foundation", "Presentation", "Persistence", "Integration", "Messaging", "Observability"].enumerated() {
            let layer = editor.instance(of: [layerType.id], words: name, at: CGPoint(x: away.x + 500 + 220 * CGFloat(place), y: away.y + 400))
            editor.galleryArrow(feature, layer, of: relationshipID)
        }
        editor.selection = nil
        guard case .related(let pills, let more) = try relationRow(stage, feature, "in").content, pills.count == 2, more == 4,
              pills.map(\.label) == ["Foundation", "Integration"] else {
            throw GalleryFailure("two pills in name order and the rest counted")
        }
        return canvas(stage)
    },
    GalleryState("relations-both-ends", "a relationship drawn: the Feature note's `in` row holds a pill for the Layer note, and the Layer note's `feature` row a pill for the Feature note", size: CGSize(width: 860, height: 340)) { stage in
        let editor = stage.editor
        editor.drawnEnds()
        let feature = editor.instance(of: [featureType.id], words: "", ["purpose": "sign in with no password"], at: CGPoint(x: 40, y: 40))
        let layer = editor.instance(of: [layerType.id], words: "", ["order": 1, "purpose": "expose foobar", "title": "foundation"], at: CGPoint(x: 460, y: 40))
        editor.galleryArrow(feature, layer, of: relationshipID)
        editor.selection = nil
        guard case .related(let one, 0) = try relationRow(stage, feature, "in").content, one.map(\.target) == [layer],
              case .related(let two, 0) = try relationRow(stage, layer, "feature").content, two.map(\.target) == [feature] else {
            throw GalleryFailure("a pill in the row of each note")
        }
        return canvas(stage)
    },
    GalleryState("relations-dashed-states", "a pill in each state: solid through a reference that reads through; dashed for a note the reference may not stand for, a note that is gone, several notes, a note on a board that can't be shown, and nothing",
                 size: manyStage) { stage in
        let editor = stage.editor
        editor.drawnEnds()
        @MainActor func note(_ place: Int, _ words: String) -> ShapeID {
            editor.instance(of: [featureType.id], words: words, [:], at: CGPoint(x: 40 + 380 * CGFloat(place % 3), y: 40 + 270 * CGFloat(place / 3)))
        }
        @MainActor func layer(_ words: String, public isPublic: Bool) -> ShapeID {
            let id = editor.instance(of: [layerType.id], words: words, at: CGPoint(x: away.x + 500 + 220 * CGFloat(editor.document.shapes.count), y: away.y + 800))
            if !isPublic { editor.transact("Private") { $0.update(id) { $0[PrivateProperty.self] = true } } }
            return id
        }
        let spot = CGPoint(x: away.x, y: away.y + 1200)
        // Through a pill, and live.
        let live = note(0, "reads through")
        let foundation = layer("Foundation", public: true)
        editor.galleryArrow(live, editor.galleryPill(for: foundation, label: "Foundation", at: spot), of: relationshipID)
        // A pill that may not stand for its note.
        let held = note(1, "not public")
        let private_ = layer("Presentation", public: false)
        editor.galleryArrow(held, editor.galleryPill(for: private_, label: "Presentation", at: CGPoint(x: spot.x + 200, y: spot.y)), of: relationshipID)
        // A pill whose note is gone.
        let goneNote = note(2, "note deleted")
        let deleted = layer("Persistence", public: true)
        editor.galleryArrow(goneNote, editor.galleryPill(for: deleted, label: "Persistence", at: CGPoint(x: spot.x + 400, y: spot.y)), of: relationshipID)
        editor.transact("Delete") { $0.delete([deleted]) }
        // A pill that finds several notes.
        let several = note(3, "finds several")
        var query = Reference(frame: CGRect(origin: CGPoint(x: spot.x + 600, y: spot.y), size: Reference.defaultSize), all: true)
        ReferenceEdits.find(&query, words: "every layer", query: "sticky-note")
        editor.galleryArrow(several, editor.add(query), of: relationshipID)
        // A pill whose note is on a board the app can't show (its owner is not in the file).
        let hidden = note(5, "on a board that is not shown")
        let elsewhere = layer("Observability", public: true)
        editor.galleryArrow(hidden, editor.galleryPill(for: elsewhere, label: "Observability", at: CGPoint(x: spot.x + 1000, y: spot.y)), of: relationshipID)
        let record = try require(editor.document[elsewhere])
        editor.transact("Delete") { $0.delete([elsewhere]) }
        editor.replaceFile(with: CanvasFile(root: editor.file.root, children: editor.file.children.merging([ShapeID(): CanvasDocument(shapes: [record])]) { first, _ in first }),
                           showing: .root)
        // A pill that stands for nothing.
        let nothing = note(4, "stands for nothing")
        var blank = Reference(frame: CGRect(origin: CGPoint(x: spot.x + 800, y: spot.y), size: Reference.defaultSize))
        ReferenceEdits.clear(&blank)
        editor.galleryArrow(nothing, editor.add(blank), of: relationshipID)
        editor.selection = nil
        @MainActor func state(_ id: ShapeID) throws -> EndReading {
            let found = try relationRow(stage, id, "in")
            guard case .related(let pills, _) = found.content, let one = pills.first else { throw GalleryFailure("a pill") }
            return one.state
        }
        guard case .note = try state(live), case .notAdmitted = try state(held), case .gone = try state(goneNote), case .query = try state(several),
              case .unavailable = try state(hidden), case .empty = try state(nothing) else {
            throw GalleryFailure("each note's pill reads its own state: \(try state(live)), \(try state(held)), \(try state(goneNote)), \(try state(several)), \(try state(hidden)), \(try state(nothing))")
        }
        return canvas(stage)
    },
    GalleryState("relations-zoomed-out", "the same zoomed out to 30%: a name bar for each relation row, none for its value, and nothing for the dashed line", size: single) { stage in
        let editor = stage.editor
        editor.put(featureType, at: CGPoint(x: 40, y: 40))
        editor.put(layerType, at: CGPoint(x: 480, y: 40))
        editor.putRelationshipType(at: CGPoint(x: 330, y: 420))
        editor.galleryArrow(featureType.id, relationshipID)
        editor.galleryArrow(relationshipID, layerType.id)
        let feature = editor.instance(of: [featureType.id], words: "Sign in", ["purpose": "sign in with no password"], at: CGPoint(x: 40, y: 760))
        let layer = editor.instance(of: [layerType.id], words: "Foundation", ["order": 1], at: CGPoint(x: 480, y: 760))
        editor.galleryArrow(feature, layer, of: relationshipID)
        editor.selection = nil
        guard editor.rowBook?.rows(of: feature).last?.relation != nil else { throw GalleryFailure("the Feature note has its relation row") }
        let state = canvas(stage, zoom: 0.3)
        guard editor.drawsSkeletons else { throw GalleryFailure("the board is drawn as skeletons at 30%") }
        return state
    },
]
    + releaseStates + definitionStates + pickStates + wordsStates + arrowCardStates + selfStates + ruleStates

// MARK: The release (slice 3b)

let releaseStage = CGSize(width: 1_180, height: 700)

extension GalleryStage {
    /// A port's drag from the right dot of a shape to the middle of another, at a view point's speed of 3 a millisecond,
    /// released unless told not to. The camera is at the origin and the zoom 1, so a view point is a world point.
    func dragPort(from: ShapeID, to: ShapeID, release: Bool = true) throws {
        look(at: .zero)
        guard let source = editor.shapeContext.frame(of: from), let target = editor.shapeContext.frame(of: to) else { throw GalleryFailure("both shapes are on the board") }
        var time: TimeInterval = 10
        func event(_ point: CGPoint) -> PointerEvent { time += 0.016; return PointerEvent(location: point, timestamp: time, clickCount: 1) }
        let center = CGPoint(x: source.midX, y: source.midY), dot = CGPoint(x: source.maxX + 12, y: source.midY), end = CGPoint(x: target.midX, y: target.midY)
        editor.pointerMoved(PointerEvent(location: center, timestamp: time, clickCount: 0))
        editor.pointerMoved(PointerEvent(location: dot, timestamp: time + 0.016, clickCount: 0))
        editor.pointerDown(event(dot))
        let steps = max(1, Int((dot.distance(to: end) / 48).rounded(.up)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            editor.pointerDragged(event(CGPoint(x: dot.x + (end.x - dot.x) * t, y: dot.y + (end.y - dot.y) * t)))
        }
        if release { editor.pointerUp(event(end)) }
    }
}

/// Feature and Layer types at the top of the stage with room between them, and a Feature note and a Layer note under them.
@MainActor
func releaseBoard(_ stage: GalleryStage) -> (feature: ShapeID, layer: ShapeID, featureNote: ShapeID, layerNote: ShapeID) {
    let editor = stage.editor
    let feature = editor.put(featureType, at: CGPoint(x: 40, y: 40)), layer = editor.put(layerType, at: CGPoint(x: 780, y: 40))
    let featureNote = editor.instance(of: [feature], words: "", ["purpose": "sign in with no password"], at: CGPoint(x: 40, y: 440))
    let layerNote = editor.instance(of: [layer], words: "", ["order": 1, "purpose": "expose foobar", "title": "foundation"], at: CGPoint(x: 780, y: 440))
    editor.selection = nil
    return (feature, layer, featureNote, layerNote)
}

@MainActor
func relationshipTypeMade(_ editor: CanvasEditor) throws -> ShapeID {
    try editor.document.shapes.last { $0[RelationshipProperty.self] == true }.map(\.id).orThrow(GalleryFailure("a relationship type was made"))
}

@MainActor
let releaseStates: [GalleryState] = [
    GalleryState("Rel1-p1-dots", answers: "Board 1, step 1", "the pointer on the Feature type's note: four dots, one on each side", size: releaseStage) { stage in
        let board = releaseBoard(stage)
        let rest = stage.render(at: .zero)
        let frame = try stage.editor.shapeContext.frame(of: board.feature).orThrow(GalleryFailure("the type's frame"))
        stage.hover(at: CGPoint(x: frame.midX, y: frame.midY))
        let hovered = stage.render(at: .zero)
        guard changedPixels(rest, hovered, in: CGRect(origin: .zero, size: releaseStage)) > 100 else { throw GalleryFailure("the dots are drawn") }
        return .image(hovered)
    },
    GalleryState("Rel1-p2-dragging", answers: "Board 1, step 2", "a drag from the Feature type's right dot onto the Layer type: an arrow follows the pointer, the Layer type outlined as its target", size: releaseStage) { stage in
        let board = releaseBoard(stage)
        try stage.dragPort(from: board.feature, to: board.layer, release: false)
        guard stage.editor.session != nil, stage.editor.document.shapes.contains(where: { $0.kind == Arrow.kind }) else { throw GalleryFailure("an arrow is being dragged") }
        let picture = stage.render(at: .zero)
        let frame = try stage.editor.shapeContext.frame(of: board.layer).orThrow(GalleryFailure("the target"))
        stage.release(at: CGPoint(x: frame.midX, y: frame.midY))
        return .image(picture)
    },
    GalleryState("Rel1-p3-landed", answers: "Board 1, step 3", "released: a relationship type as a pill on the line between the two types, an arrow to it from each, selected and its name edited in place, the caret in it; the notes under show their new rows",
                 size: releaseStage) { stage in
        let board = releaseBoard(stage)
        try stage.dragPort(from: board.feature, to: board.layer)
        let made = try relationshipTypeMade(stage.editor)
        guard stage.editor.selectedShapeIDs == [made], stage.editor.editingShapeID == made, stage.editor.card == nil,
              stage.editor.shapeContext.frame(of: made)?.size == TypePills.pill(title: nil, fields: 0).size,
              stage.editor.document.shapes.filter({ $0.kind == Arrow.kind }).count == 2 else {
            throw GalleryFailure("a relationship type pill, selected and edited in place, and two arrows")
        }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel1-p4-rows-after", answers: "Board 1, step 4", "at once, before a name: the Feature note lists `add layer` under a dashed line and the Layer note `add feature`; neither note's record changed",
                 size: releaseStage) { stage in
        let board = releaseBoard(stage)
        let before = (stage.editor.document[board.featureNote], stage.editor.document[board.layerNote])
        try stage.dragPort(from: board.feature, to: board.layer)
        stage.editor.endEditing()
        stage.editor.selection = nil
        guard try relationRow(stage, board.featureNote, "layer").content == .empty("add layer"), try relationRow(stage, board.layerNote, "feature").content == .empty("add feature"),
              stage.editor.document[board.featureNote] == before.0, stage.editor.document[board.layerNote] == before.1 else {
            throw GalleryFailure("each note has its empty row and neither record changed")
        }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel1-p5-named", answers: "Board 1, step 5", "`in` typed in the pill and Return: the relationship type's pill reads `in`, solid in its color, on its line", size: releaseStage) { stage in
        let board = releaseBoard(stage)
        try stage.dragPort(from: board.feature, to: board.layer)
        let made = try relationshipTypeMade(stage.editor)
        guard let field = stage.canvas.descendants(TypePillEditor.self).first?.field else { throw GalleryFailure("the pill has its line") }
        field.insertText("in", replacementRange: NSRange(location: 0, length: 0))
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        guard stage.editor.editingShapeID == nil, stage.editor.document[made]?[TitleProperty.self] == "in" else { throw GalleryFailure("named, and editing over") }
        stage.editor.selection = nil
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel1-p6-fields", answers: "Board 1, step 6 of the pill design", "the relationship type `owner` with two fields, at rest: `owner · 2`, solid in its color, on its line", size: releaseStage) { stage in
        let board = releaseBoard(stage)
        try stage.dragPort(from: board.feature, to: board.layer)
        let made = try relationshipTypeMade(stage.editor)
        guard let field = stage.canvas.descendants(TypePillEditor.self).first?.field else { throw GalleryFailure("the pill has its line") }
        field.insertText("owner", replacementRange: NSRange(location: 0, length: 0))
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        stage.editor.transact("Fields") { $0.update(made) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"since": {"type": "string", "format": "date"}, "primary": {"type": "boolean"}}}"#) } }
        guard stage.editor.rowBook?.pill(of: made)?.fields == 2 else { throw GalleryFailure("the pill counts two fields") }
        stage.editor.selection = nil
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel1-p12-zoomed-out", answers: "Board 1, the pill design's zoomed-out frame", "the same board at 20%: the pill is a capsule in its color with no letters, on its line between the types' skeletons", size: releaseStage) { stage in
        let board = releaseBoard(stage)
        try stage.dragPort(from: board.feature, to: board.layer)
        let made = try relationshipTypeMade(stage.editor)
        guard let field = stage.canvas.descendants(TypePillEditor.self).first?.field else { throw GalleryFailure("the pill has its line") }
        field.insertText("owner", replacementRange: NSRange(location: 0, length: 0))
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        stage.editor.selection = nil
        let picture = stage.render(at: .zero, zoom: 0.2)
        guard stage.editor.drawsSkeleton(of: made) else { throw GalleryFailure("skeletons are drawn") }
        return .image(picture)
    },
    GalleryState("Rel1-p13-line-straight", answers: "Board 1, the pill design's pair of halves", "the pair at rest, named and with two fields: one line through the pill, no head at it and the head at the Layer type, no words on either half", size: releaseStage) { stage in
        let line = try ownerLine(stage)
        let c = [line.feature, line.hub, line.layer].compactMap { stage.editor.shapeContext.frame(of: $0) }.map { CGPoint(x: $0.midX, y: $0.midY) }
        guard isStraight(line, stage.editor) else { throw GalleryFailure("both halves are straight: the middles \(c)") }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel1-p13-line-moved", answers: "Board 1, frame 13: move a type", "the Layer type moved down: the pill stays where it is and the two halves are one smooth arc through it, the head at the Layer type",
                 size: releaseStage) { stage in
        let line = try ownerLine(stage)
        let pill = try stage.editor.shapeContext.frame(of: line.hub).orThrow(GalleryFailure("the pill"))
        stage.editor.transact("Move") { $0.translate([line.layer], by: CGPoint(x: 0, y: 300)) }
        guard stage.editor.shapeContext.frame(of: line.hub) == pill, !isStraight(line, stage.editor) else { throw GalleryFailure("the pill stayed and the line is an arc") }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel1-p13-line-dragged", answers: "Board 1, the pill dragged", "the pill dragged off the line, down: both halves bend through it",
                 size: releaseStage) { stage in
        let line = try ownerLine(stage)
        stage.editor.transact("Drag the pill") { $0.translate([line.hub], by: CGPoint(x: 0, y: 260)) }
        guard !isStraight(line, stage.editor) else { throw GalleryFailure("the line bends through the pill") }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel1-p14-pair-selected", answers: "Board 1, frame 14: select the pair", "the relationship type selected: the pill and both halves outlined together",
                 size: releaseStage) { stage in
        let line = try ownerLine(stage)
        stage.editor.pointerMoved(PointerEvent(location: CGPoint(x: 600, y: 600), timestamp: 100, clickCount: 0))
        stage.editor.selection = line.hub
        guard Set(stage.editor.outlines.shapes) == Set([line.hub] + line.ends) else { throw GalleryFailure("the pill and both halves are outlined") }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel1-p14-half-selected", answers: "Board 1, frame 14: select one end", "one half of the line selected alone, with its end handles; the pill and the other half as they are",
                 size: releaseStage) { stage in
        let line = try ownerLine(stage)
        let half = try line.ends.first { stage.editor.relationships?.end($0)?.side == .from }.orThrow(GalleryFailure("a from end"))
        stage.editor.pointerMoved(PointerEvent(location: CGPoint(x: 600, y: 600), timestamp: 100, clickCount: 0))
        stage.editor.selection = half
        guard stage.editor.outlines.shapes == [half] else { throw GalleryFailure("only the half is outlined") }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel1-p13-line-zoomed-out", answers: "Board 1, frame 12 with the arc", "the moved Layer type's arc at 30%: capsule in the middle, both halves' skeletons on the same arc, the head at the Layer type only",
                 size: releaseStage) { stage in
        let line = try ownerLine(stage)
        stage.editor.transact("Move") { $0.translate([line.layer], by: CGPoint(x: 0, y: 300)) }
        let picture = stage.render(at: .zero, zoom: 0.3)
        guard stage.editor.drawsSkeleton(of: line.hub), !isStraight(line, stage.editor) else { throw GalleryFailure("skeletons, on an arc") }
        return .image(picture)
    },
    GalleryState("Rel1-p19-long", answers: "Board 1, the pill design's long-name frame", "a long name: the pill stops at 240 points and ends in an ellipsis, the count first", size: releaseStage) { stage in
        let board = releaseBoard(stage)
        try stage.dragPort(from: board.feature, to: board.layer)
        let made = try relationshipTypeMade(stage.editor)
        guard let field = stage.canvas.descendants(TypePillEditor.self).first?.field else { throw GalleryFailure("the pill has its line") }
        field.insertText("the person who owns the car and keeps it garaged", replacementRange: NSRange(location: 0, length: 0))
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        stage.editor.transact("Fields") { $0.update(made) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"since": {"type": "string"}, "primary": {"type": "boolean"}}}"#) } }
        guard stage.editor.shapeContext.frame(of: made)?.width == TypesStyle.pillMaximumWidth else { throw GalleryFailure("the pill is at its widest") }
        stage.editor.selection = nil
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel1-p9-took", answers: "Board 1, step 9", "a drag from the Feature note to the Layer note once `in` is named: the arrow is of `in` at once, its pill in the line, no list; the Feature note's `layer` row holds a pill",
                 size: releaseStage) { stage in
        let board = releaseBoard(stage)
        try stage.dragPort(from: board.feature, to: board.layer)
        let made = try relationshipTypeMade(stage.editor)
        guard let field = stage.canvas.descendants(TypePillEditor.self).first?.field else { throw GalleryFailure("the pill has its line") }
        field.insertText("in", replacementRange: NSRange(location: 0, length: 0))
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        stage.editor.selection = nil
        try stage.dragPort(from: board.featureNote, to: board.layerNote)
        guard let arrow = stage.editor.document.shapes.last(where: { $0.kind == Arrow.kind }), arrow[IsAProperty.self]?.map(\.shape) == [made],
              stage.editor.menuToPopUp == nil else { throw GalleryFailure("the arrow took `in` and no list opened") }
        stage.editor.selection = nil
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel3-p3-list", answers: "Board 3, frame 3.3", "a drag between two notes that two relationship types fit: the list at the arrow (outline), the taken types by name, a rule, a gray Plain arrow; the arrow is selected while it is open",
                 size: releaseStage, isText: true) { stage in
        let editor = stage.editor
        let person = editor.put(FieldFixtures.person, at: CGPoint(x: 40, y: 40)), company = editor.put(FieldFixtures.address, at: CGPoint(x: 780, y: 40))
        let friendship = editor.addTypeNote(TypeSchemaProperty.starter, text: "", title: "Friendship", frame: CGRect(x: 400, y: 40, width: 200, height: 200), id: rowsTypeID(90))
        let mentorship = editor.addTypeNote(TypeSchemaProperty.starter, text: "", title: "Mentorship", frame: CGRect(x: 400, y: 300, width: 200, height: 200), id: rowsTypeID(91))
        editor.transact("Mark") { transaction in for id in [friendship, mentorship] { transaction.update(id) { $0[RelationshipProperty.self] = true } } }
        for type in [friendship, mentorship] {
            editor.galleryArrow(person, type)
            editor.galleryArrow(type, company)
        }
        let ann = editor.instance(of: [person], words: "Ann", at: CGPoint(x: 40, y: 440)), bo = editor.instance(of: [company], words: "Bo", at: CGPoint(x: 780, y: 440))
        editor.selection = nil
        try stage.dragPort(from: ann, to: bo)
        guard let (menu, _) = editor.menuToPopUp, let arrow = editor.document.shapes.last(where: { $0.kind == Arrow.kind })?.id,
              editor.selectedShapeIDs == [arrow] else { throw GalleryFailure("the list is open and the arrow is selected") }
        var lines = menu.outline
        if let highlighted = editor.menuItemToHighlight { lines.append("highlighted: \(highlighted.title)") }
        lines.append("selected: the arrow")
        return .text(lines.joined(separator: "\n") + "\n")
    },
]

/// Feature and Layer at the top of the stage, a level line apart, with a relationship type `owner` (two fields) drawn between them by a port's drag:
/// one line through the pill. Nothing selected.
@MainActor
func ownerLine(_ stage: GalleryStage) throws -> (hub: ShapeID, feature: ShapeID, layer: ShapeID, ends: [ShapeID]) {
    let board = releaseBoard(stage)
    try stage.dragPort(from: board.feature, to: board.layer)
    let made = try relationshipTypeMade(stage.editor)
    guard let field = stage.canvas.descendants(TypePillEditor.self).first?.field else { throw GalleryFailure("the pill has its line") }
    field.insertText("owner", replacementRange: NSRange(location: 0, length: 0))
    field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    stage.editor.transact("Fields") { $0.update(made) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"since": {"type": "string", "format": "date"}, "primary": {"type": "boolean"}}}"#) } }
    // The notes under the types are beside the point, and in the way of a type moved.
    stage.editor.transact("Clear") { $0.delete([board.featureNote, board.layerNote]) }
    stage.editor.selection = nil
    let ends = Array(try stage.editor.relationships.orThrow(GalleryFailure("relationships")).endArrows(of: made))
    return (made, board.feature, board.layer, ends)
}

/// Whether both halves of the line are drawn straight now.
@MainActor
func isStraight(_ line: (hub: ShapeID, feature: ShapeID, layer: ShapeID, ends: [ShapeID]), _ editor: CanvasEditor) -> Bool {
    line.ends.count == 2 && line.ends.allSatisfy { arrow in
        if case .straight? = editor.arrowGeometry(of: arrow)?.path { true } else { false }
    }
}
