import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import Selection
import StickyNotes
import TestKit
import Types
import Validation

// The gallery's states for Needed and Only one (slice 5b), appended to `relationStates`: a type's note with a Needed row (the
// amber dot after the row's name), a note with an empty Needed row (`add layer` in amber, no ring), a note that breaks Only one
// (the row's pills red with the wave, the ring, and the Issues sentence), and the end arrow's menu with its two items (as its
// outline, a text file: a menu is not drawn offscreen).

private let ruleStage = CGSize(width: 860, height: 640)
private let noteStage = CGSize(width: 860, height: 420)
private let tallStage = CGSize(width: 860, height: 760)

/// The arrow from Feature into the relationship type: the end at Feature.
@MainActor
private func featureEnd(_ editor: CanvasEditor) throws -> ShapeID {
    try require(editor.relationships?.graph.sides(of: rulesRelationshipID).from.first?.carrier, "the end at Feature")
}

private let rulesRelationshipID = rowsTypeID(82)

@MainActor
private func issues(_ stage: GalleryStage, _ id: ShapeID) -> [String] {
    _ = stage.editor.validation?.results
    return stage.editor.validation?.result(for: id)?.issues.map(\.message) ?? []
}

@MainActor
let ruleStates: [GalleryState] = [
    GalleryState("Rel2-p6-needed-type-row", answers: "Board 2, frame 4.6",
                 "the Feature type with its end marked Needed: the amber dot after the name of its `layer` row, as a required field has one; the Layer type's `feature` row has none",
                 size: ruleStage) { stage in
        let editor = stage.editor
        editor.put(featureType, at: CGPoint(x: 40, y: 40))
        editor.put(layerType, at: CGPoint(x: 480, y: 40))
        editor.putRelationshipType(at: CGPoint(x: 330, y: 420))
        let end = editor.galleryArrow(featureType.id, rulesRelationshipID)
        editor.galleryArrow(rulesRelationshipID, layerType.id)
        guard editor.setEndRule([end], needed: true), editor.undoHistory.undoName == "Make Needed" else { throw GalleryFailure("Needed is set in one step") }
        editor.selection = nil
        guard editor.relationships?.graph.rows(for: [featureType.id], isType: true).first?.rule.needed == true else { throw GalleryFailure("the row is Needed") }
        return canvas(stage)
    },
    GalleryState("Rel2-p6-needed-empty-row", answers: "Board 2, frame 4.6",
                 "a Feature note with nothing in its Needed row: `add layer` in amber under the dashed line, no ring and nothing red",
                 size: noteStage) { stage in
        let editor = stage.editor
        editor.drawnEnds()
        let feature = editor.instance(of: [featureType.id], words: "", ["purpose": "sign in with no password"], at: CGPoint(x: 40, y: 40))
        let layer = editor.instance(of: [layerType.id], words: "", ["order": 1, "purpose": "expose foobar", "title": "foundation"], at: CGPoint(x: 460, y: 40))
        _ = layer
        let end = try featureEnd(editor)
        guard editor.setEndRule([end], needed: true) else { throw GalleryFailure("Needed is set") }
        editor.selection = nil
        // What the note still needs is an issue Validation keeps, at the level that shows nowhere: no ring and no Issues line.
        guard let check = editor.fieldChecks?.check(of: try require(editor.document[feature])), check.isIncomplete, !check.isWrong,
              issues(stage, feature).count == 1, editor.validation?.result(for: feature)?.worst == nil
        else { throw GalleryFailure("the note is incomplete, Validation keeps that as its one issue, and none of it shows") }
        return canvas(stage)
    },
    GalleryState("Rel2-p6-only-one-broken", answers: "Board 2, frame 4.6",
                 "a Feature note whose `layer` row is Only one and holds two Layer notes: both pills red with the wave, and the red ring round the note",
                 size: tallStage) { stage in
        let editor = stage.editor
        editor.drawnEnds()
        let feature = editor.instance(of: [featureType.id], words: "", ["purpose": "sign in with no password"], at: CGPoint(x: 40, y: 40))
        let foundation = editor.instance(of: [layerType.id], words: "Foundation", at: CGPoint(x: 460, y: 40))
        let roof = editor.instance(of: [layerType.id], words: "Roof", at: CGPoint(x: 460, y: 500))
        guard editor.setEndRule([try featureEnd(editor)], onlyOne: true) else { throw GalleryFailure("Only one is set") }
        editor.galleryArrow(feature, foundation, of: rulesRelationshipID)
        editor.galleryArrow(feature, roof, of: rulesRelationshipID)
        editor.selection = nil
        guard editor.fieldChecks?.check(of: try require(editor.document[feature])).isWrong == true,
              editor.validation?.result(for: feature)?.isValid == false else { throw GalleryFailure("the note is wrong and rings") }
        return canvas(stage)
    },
    GalleryState("Rel2-p6-only-one-issues", answers: "Board 2, frame 4.6", "the Issues sentence of that note, naming the row", size: noteStage, isText: true) { stage in
        let editor = stage.editor
        editor.drawnEnds()
        let feature = editor.instance(of: [featureType.id], words: "", ["purpose": "sign in with no password"], at: CGPoint(x: 40, y: 40))
        let foundation = editor.instance(of: [layerType.id], words: "Foundation", at: CGPoint(x: 460, y: 40))
        let roof = editor.instance(of: [layerType.id], words: "Roof", at: CGPoint(x: 460, y: 500))
        editor.setEndRule([try featureEnd(editor)], onlyOne: true)
        let first = editor.galleryArrow(feature, foundation, of: rulesRelationshipID), second = editor.galleryArrow(feature, roof, of: rulesRelationshipID)
        let said = issues(stage, feature)
        guard said == ["in has 2 notes, and should have at most 1"], issues(stage, first).isEmpty, issues(stage, second).isEmpty else {
            throw GalleryFailure("one sentence on the note, none on the arrows: \(said)")
        }
        return .text("note\n\(said.map { "error: \($0)" }.joined(separator: "\n"))\n")
    },
    GalleryState("Rel2-p6-end-menu", answers: "Board 2, frame 4.6",
                 "the menu of the end arrow from Feature into the relationship type, a right-click on it: Needed and Only one among the state items, beside Lock and Is a (outline); Needed is checked once it is set",
                 size: ruleStage, isText: true) { stage in
        let editor = stage.editor
        editor.put(featureType, at: CGPoint(x: 40, y: 40))
        editor.put(layerType, at: CGPoint(x: 480, y: 40))
        editor.putRelationshipType(at: CGPoint(x: 330, y: 420))
        let end = editor.galleryArrow(featureType.id, rulesRelationshipID)
        editor.galleryArrow(rulesRelationshipID, layerType.id)
        stage.look(at: .zero)
        let outline = try require(editor.shapeContext.geometry(of: end)?.outline, "the end arrow's line")
        let middle = stage.viewPoint(outline[outline.count / 2])
        editor.selectedShapeIDs = [end]
        let plain = stage.menuOutline(at: middle)
        guard plain.contains("Needed"), plain.contains("Only one"), !plain.contains("✓ Needed") else { throw GalleryFailure("both items, unchecked: \(plain)") }
        editor.setEndRule([end], needed: true)
        editor.selectedShapeIDs = [end]
        let checked = stage.menuOutline(at: middle)
        guard checked.contains("✓ Needed"), checked.contains("Only one") else { throw GalleryFailure("Needed checked: \(checked)") }
        return .text((["the end arrow's menu"] + plain + ["", "once Needed is set"] + checked).joined(separator: "\n") + "\n")
    },
]
