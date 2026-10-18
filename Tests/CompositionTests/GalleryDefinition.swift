import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Foundation
import Mentions
import Selection
import StickyNotes
import TestKit
import Titles
import Types

// The card that defines a relationship type (slice 3 of the pill design): the states are made as a person makes them. A drag
// from the Feature type to the Layer type lands the pill, `owner` is typed in it, and Tab opens the card at `add field`
// (`DefinitionCards`); the fields are typed in it, or written through the one writer for the states that start from a few.

/// The Feature to Layer board with the relationship type named `owner` and its card open at `add field`.
@MainActor
private func openedCard(_ stage: GalleryStage) throws -> (hub: ShapeID, view: DefinitionView, board: (feature: ShapeID, layer: ShapeID, featureNote: ShapeID, layerNote: ShapeID)) {
    let board = releaseBoard(stage)
    try stage.dragPort(from: board.feature, to: board.layer)
    let hub = try relationshipTypeMade(stage.editor)
    guard let field = stage.canvas.descendants(TypePillEditor.self).first?.field else { throw GalleryFailure("the pill has its line") }
    field.insertText("owner", replacementRange: NSRange(location: 0, length: 0))
    field.doCommand(by: #selector(NSResponder.insertTab(_:)))
    guard stage.editor.definitionCards?.openType == hub, let view = stage.editor.definitionCards?.openView, view.focus == .addField else {
        throw GalleryFailure("Tab in the name opened the card at add field")
    }
    return (hub, view, board)
}

@MainActor
let definitionStates: [GalleryState] = [
    GalleryState("Rel3-card-empty", answers: "The pill design, frame 4", "Tab in the name `owner`: the card under the pill, the name, an empty `add field` with the caret, a hairline, and a line for each end (the Feature type's `owner`, the Layer type's `feature`) with Needed and Only one",
                 size: releaseStage) { stage in
        _ = try openedCard(stage)
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel3-card-kinds", answers: "The pill design, frame 4", "`since` typed in `add field` and Tab: the field is there as Text and its kinds are listed under it, Text taken", size: releaseStage) { stage in
        let opened = try openedCard(stage)
        stage.window.type("since")
        stage.window.press("\t", code: 48)
        guard opened.view.listing == "since", opened.view.fields.map(\.name) == ["since"] else { throw GalleryFailure("the field is added and its kinds listed") }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel3-card-kinds-list", answers: "The pill design, frame 4", "the kinds listed under a field, as text", size: releaseStage, isText: true) { stage in
        let opened = try openedCard(stage)
        stage.window.type("since")
        stage.window.press("\t", code: 48)
        stage.window.press("\u{F701}", code: 125)
        stage.window.press("\u{F701}", code: 125)
        guard opened.view.listing == "since" else { throw GalleryFailure("the kinds are listed") }
        let lines = opened.view.listedKinds.enumerated().map { place, kind in (place == opened.view.highlight ? "> " : "  ") + kind.label }
        return .text(lines.joined(separator: "\n"))
    },
    GalleryState("Rel3-card-fields", answers: "The pill design, frame 5", "two fields and a Choice: `since` Date, `primary` Yes or no, `color` Choice with its options as indented lines and an empty one that adds, the caret in it; the pill reads `owner · 3`",
                 size: releaseStage) { stage in
        let opened = try openedCard(stage)
        let definer = try require(stage.editor.fieldDefiner)
        definer.addField(named: "since", kind: .date, to: opened.hub)
        definer.addField(named: "primary", kind: .yesNo, to: opened.hub)
        definer.addField(named: "color", kind: .choice, to: opened.hub)
        definer.addOption("red", to: "color", in: opened.hub)
        definer.addOption("blue", to: "color", in: opened.hub)
        opened.view.focus(.newOption("color"))
        guard stage.editor.rowBook?.pill(of: opened.hub)?.fields == 3 else { throw GalleryFailure("the pill counts three fields") }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel3-card-only-one", answers: "The pill design, frame 5", "`since` as a Date and Only one ticked on the Feature type's line, so its row on the Feature note reads `owner` with a soft 1", size: releaseStage) { stage in
        let opened = try openedCard(stage)
        stage.editor.fieldDefiner?.addField(named: "since", kind: .date, to: opened.hub)
        let carrier = try require(stage.editor.relationships?.graph.sides(of: opened.hub).from.first?.carrier)
        opened.view.focus(.onlyOne(carrier))
        stage.window.press(" ", code: 49)
        guard stage.editor.shape(inFile: carrier)?[RelationshipEndProperty.self]?.onlyOne == true else { throw GalleryFailure("Only one is ticked") }
        return .image(stage.render(at: .zero))
    },
    GalleryState("Rel3-panel-description", answers: "The pill design, the panel", "the relationship type `owner` selected, its Schema tab: Description, its words, from which the model wrote the fields, above the JSON", size: CGSize(width: 320, height: 560)) { stage in
        let board = releaseBoard(stage)
        try stage.dragPort(from: board.feature, to: board.layer)
        let hub = try relationshipTypeMade(stage.editor)
        guard let field = stage.canvas.descendants(TypePillEditor.self).first?.field else { throw GalleryFailure("the pill has its line") }
        field.insertText("owner", replacementRange: NSRange(location: 0, length: 0))
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        // The words as typed in the box, and the fields the model wrote from them.
        stage.editor.transact { $0.update(hub, as: StickyNote.self) { $0.props.text = MentionText(plain: "Who owns the car, since when, and whether they're its main owner.") } }
        guard let definer = stage.editor.fieldDefiner, definer.addField(named: "since", kind: .date, to: hub) != nil,
              definer.addField(named: "primary", kind: .yesNo, to: hub) != nil else { throw GalleryFailure("the fields are written") }
        return .image(try stage.panelPicture(of: hub, tab: .of(TypeSchemaTab.self), size: CGSize(width: 320, height: 560)))
    },
]
