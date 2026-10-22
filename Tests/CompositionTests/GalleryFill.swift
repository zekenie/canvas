import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import DetailPanel
import Foundation
import LanguageModels
import Selection
import StickyNotes
import TestKit
import Types

// The gallery's states for a note's fields filled from its words (`FieldFill`): the owner's Feature note while the
// model reads it (its empty rows a bar each), once it has (only what the words say filled), its panel's Types tab with
// Advanced folded, filling and not, Advanced opened on its box, and a type whose notes don't fill, its `$autofill` in
// its JSON.

private let single = CGSize(width: 440, height: 340)

/// The owner's Feature, with a status and an estimate beside its purpose: what the words don't say stays empty.
private let feature: FieldFixtures.TypeText = (rowsTypeID(60), "Feature", "A feature has a purpose, a status and an estimate in days.",
                                               #"{"type": "object", "properties": {"purpose": {"type": "string"}, "status": {"enum": ["todo", "doing", "done"]}, "estimate": {"type": "integer"}}}"#)

/// The owner's note.
private let ownerWords = "purpose is to be a foobar really good foob"

/// A note of the Feature saying the owner's words, its fill asked for (words never read, as editing it ends); `answer`
/// lands, or, with none, the call is held out.
@MainActor
private func featureNote(_ stage: GalleryStage, answer: String?) throws -> ShapeID {
    stage.editor.offstage([feature])
    let id = stage.editor.instance(of: [feature.id], words: ownerWords)
    stage.editor.selection = nil
    let fill = try require(stage.editor.fieldFill)
    if let answer {
        stage.model.queue(answer)
    } else {
        stage.model.holdsAnswers = true
    }
    fill.editingDidEnd(id, in: stage.editor)
    stage.scheduler.advance(by: .zero)
    if answer == nil {
        spinRunLoop(until: { stage.model.waiting == 1 })
    } else {
        spinRunLoop(until: { fill.status(of: id) == .idle && stage.model.requests.contains { $0.system == FillPrompts.system } })
    }
    return id
}

@MainActor
let fillStates: [GalleryState] = [
    GalleryState("Fill-p1-filling", "the owner's Feature note while its words are read: each empty field a bar where `add …` was", size: single) { stage in
        _ = try featureNote(stage, answer: nil)
        return canvas(stage)
    },
    GalleryState("Fill-p2-filled", "the answer landed: `purpose` says `to be a foobar really good foob`; status and estimate stay empty", size: single) { stage in
        _ = try featureNote(stage, answer: #"{"purpose": "to be a foobar really good foob"}"#)
        return canvas(stage)
    },
    GalleryState("Fill-p3-panel", "its Types tab as it first shows: the type, the Fields, and at the foot `Advanced`, folded") { stage in
        let id = try featureNote(stage, answer: #"{"purpose": "to be a foobar really good foob"}"#)
        return .image(try stage.panelPicture(of: id))
    },
    GalleryState("Fill-p4-panel-filling", "the same while the words are read: `Filling fields…` at the foot of the Fields, Advanced still folded") { stage in
        let id = try featureNote(stage, answer: nil)
        return .image(try stage.panelPicture(of: id))
    },
    GalleryState("Fill-p5-panel-advanced", "Advanced opened: `Fill fields from words`, checked") { stage in
        let id = try featureNote(stage, answer: #"{"purpose": "to be a foobar really good foob"}"#)
        try openAdvanced(stage, id, in: .of(TypesTab.self))
        return .image(try stage.panelPicture(of: id))
    },
    GalleryState("Fill-p6-type-off", "a type whose notes don't fill: its Schema tab's Advanced opened, `Notes fill fields from words` unchecked, `$autofill` false in its JSON") { stage in
        let id = stage.editor.put(feature)
        try require(stage.editor.fieldFill).setAutofill(false, of: id)
        try openAdvanced(stage, id, in: .of(TypeSchemaTab.self))
        return .image(try stage.panelPicture(of: id, tab: .of(TypeSchemaTab.self)))
    },
]

/// Opens the section called Advanced in a shape's tab, as a click on its header does.
@MainActor
private func openAdvanced(_ stage: GalleryStage, _ id: ShapeID, in tab: DetailTabID) throws {
    let state = try require(stage.editor.detailPanel)
    let layout = state.layout(for: try require(stage.editor.document[id]))
    state.setCollapsed(try require(layout.sections(in: tab).first { $0.section.hasSuffix("autofill") }), false)
}
