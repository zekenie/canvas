import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import Mentions
import Selection
import StickyNotes
import TestKit
import Types

// The gallery's states for board 6's "Words" frame (slice 8), appended to `relationStates`: the Feature type's words "A feature has a
// purpose and is in a" and a pill of Layer, one row `purpose`, Layer apart with no arrows; a click on the pill (the menu of one item,
// `Relate to Layer`, under it, as its outline: a menu is not drawn offscreen); and the board after choosing it.

private let wordsStage = CGSize(width: 1_100, height: 520)

/// The Feature type, its words naming Layer with a pill, and the Layer type apart from it.
@MainActor
private func wordsBoard(_ stage: GalleryStage) -> (feature: ShapeID, layer: ShapeID) {
    let editor = stage.editor
    let layer = editor.put(layerType, at: CGPoint(x: 700, y: 40))
    let words = MentionText([.text("A feature has a purpose and is in a "), .mention(layer, label: "Layer"), .text(".")])
    let feature = editor.addTypeNote(featureType.schema, text: words, title: featureType.title, frame: CGRect(x: 40, y: 40, width: 360, height: 200), id: featureType.id)
    editor.selection = feature
    stage.look(at: .zero)
    return (feature, layer)
}

/// A click where the pill is, as the pointer clicks it.
@MainActor
private func clickPill(_ stage: GalleryStage, of feature: ShapeID) throws {
    guard let pill = stage.editor.mentionPills(of: feature).first?.frame else { throw GalleryFailure("the words hold a pill") }
    let point = CGPoint(x: pill.midX, y: pill.midY)
    stage.hover(at: point)
    stage.press(at: point)
    stage.release(at: point)
}

@MainActor
let wordsStates: [GalleryState] = [
    GalleryState("Rel6-p1-words", answers: "Board 6, \"They offer it\"", "the Feature type selected: its words \"A feature has a purpose and is in a\" and a pill of Layer, one row `purpose`; the Layer type apart, no arrows",
                 size: wordsStage) { stage in
        let board = wordsBoard(stage)
        guard stage.editor.mentionPills(of: board.feature).count == 1, stage.editor.document.shapes.filter({ $0.kind == Arrow.kind }).isEmpty,
              stage.editor.rowBook?.rows(of: board.feature).map(\.name) == ["purpose"] else { throw GalleryFailure("a pill, one row and no arrows") }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel6-p2-offer", answers: "Board 6, \"They offer it\"", "a click on the pill: the type is selected and not edited, and a menu of one item, Relate to Layer, waits under the pill, highlighted (a menu is its outline)",
                 size: wordsStage, isText: true) { stage in
        let board = wordsBoard(stage)
        try clickPill(stage, of: board.feature)
        guard let (menu, rect) = stage.editor.menuToPopUp, stage.editor.selectedShapeIDs == [board.feature], stage.editor.editingShapeID == nil else {
            throw GalleryFailure("the type is selected, not edited, and a menu waits")
        }
        var lines = menu.outline
        if let highlighted = stage.editor.menuItemToHighlight { lines.append("highlighted: \(highlighted.title)") }
        lines.append("under the pill: \(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width)) by \(Int(rect.height))")
        lines.append("selected: Feature")
        return .text(lines.joined(separator: "\n") + "\n")
    },
    GalleryState("Rel6-p3-related", answers: "Board 6, \"They offer it\"", "after Relate to Layer: a relationship type drawn small between the two types with an arrow to it from each, its name card open; Feature's `layer` row under a dashed line, Layer's `feature`; the words still hold the pill",
                 size: wordsStage) { stage in
        let board = wordsBoard(stage)
        let before = (stage.editor.document[board.feature], stage.editor.document[board.layer])
        try clickPill(stage, of: board.feature)
        guard let (menu, _) = stage.editor.menuToPopUp else { throw GalleryFailure("a menu waits") }
        try menu.choose("Relate to Layer")
        stage.editor.menuDidPopUp()
        guard let made = stage.editor.document.shapes.last(where: { $0[RelationshipProperty.self] == true })?.id, stage.editor.card != nil,
              stage.editor.document.shapes.filter({ $0.kind == Arrow.kind }).count == 2,
              stage.editor.document[board.feature] == before.0, stage.editor.document[board.layer] == before.1,
              stage.editor.rowBook?.rows(of: board.feature).last?.content == .relationType(direction: "→", chips: [board.layer], more: 0) else {
            throw GalleryFailure("a relationship type and two arrows, the name card open, neither type's record changed")
        }
        stage.editor.closeCard()
        stage.editor.selection = made
        return .image(stage.render(at: .zero))
    },
]
