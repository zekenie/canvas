import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Foundation
import Mentions
import Selection
import StickyNotes
import SwiftUI
import TestKit
import Titles
import Types
import Validation

// The title from a field (slice 15): a note titled from its field shows the type's chip and the name in its row, and no
// pill; a title by hand shows its pill. Added to `galleryStates` (GalleryTypesLook.swift) as `titleStates`. The types are
// the shared `namedPerson` and `namedEmployee` (Person's `$title` names `name`, Employee has none of its own) and a Staff
// of ten fields that is a Person, so the name folds into `from Person`.

private let single = CGSize(width: 440, height: 340)
private let tall = CGSize(width: 440, height: 520)

/// Person and Employee, titled by name, off the stage, Employee a Person.
@MainActor
private func namedTypes(_ stage: GalleryStage) {
    stage.editor.offstage([FieldFixtures.namedPerson, FieldFixtures.namedEmployee])
    stage.editor.addTypeLink(FieldFixtures.namedPersonID, to: FieldFixtures.namedEmployeeID)
}

/// A Staff of ten fields that is a Person: twelve fields, the name folded into `from Person`.
private let staff: FieldFixtures.TypeText = (rowsTypeID(72), "Staff", "Staff are people with a desk, a badge and eight more fields.",
                                             fieldsSchema((1...10).map { "e\($0)" }))

/// A note that is each of the types, `size` big at (60, 40), saying `words`; its name typed in through the writer, so
/// the title follows it as it does in the app.
@MainActor
@discardableResult
private func named(_ stage: GalleryStage, _ name: String?, of types: [ShapeID], words: String, size: CGSize = CGSize(width: 200, height: 200)) throws -> ShapeID {
    var note = ShapeRecord(id: ShapeID(), StickyNote(frame: CGRect(origin: CGPoint(x: 60, y: 40), size: size), text: MentionText(plain: words)))
    note[IsAProperty.self] = types.map(TypeLink.init)
    stage.editor.transact { $0.insert(AnyShapeRecord(note)) }
    if let name { expect(try require(stage.editor.fieldWriter).setTyped(name, as: .text, at: FieldPath(field: "name"), of: note.id)) }
    return note.id
}

extension GalleryStage {
    /// The panel of `id`, selected, on its Issues tab (Validation's: each issue with its words), as an unshown window draws it at 2x.
    fileprivate func issuesPicture(of id: ShapeID, size: CGSize) throws -> NSBitmapImageRep {
        let record = try require(editor.document[id])
        try require(editor.detailPanel).choose(.of(IssuesTab.self), for: record.kind)
        editor.selection = id
        let host = NSHostingView(rootView: try require(editor.registry.hostInspector).view(for: editor, onExit: {}))
        host.frame = CGRect(origin: .zero, size: size)
        let panelWindow = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        panelWindow.contentView = host
        panelWindow.appearance = appearance
        panelWindow.settle()
        spin(0.15)
        panelWindow.settle()
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        return rep
    }
}

@MainActor
let titleStates: [GalleryState] = [
    GalleryState("Flow3-p1-named", answers: "Flow3 p1", "a Person named `Ann Lee` in its row: the Person chip above the note and no title pill (the title is the name, written when the row was)", size: single) { stage in
        namedTypes(stage)
        let id = try named(stage, "Ann Lee", of: [FieldFixtures.namedPersonID], words: "Ann Lee, staff engineer since 2021.")
        stage.editor.selection = nil
        guard stage.editor.document[id]?[TitleProperty.self] == "Ann Lee" else { throw GalleryFailure("the title follows the name") }
        guard !stage.editor.adornmentFrames(of: id).contains(where: { $0.adornment == .of(TitlePill.self) }) else { throw GalleryFailure("no pill") }
        return canvas(stage)
    },
    GalleryState("Flow3-p2-employee-named", answers: "Flow3 p2", "an Employee `Bo Park`, titled through Person's `$title` (Employee has none): the Employee chip alone", size: single) { stage in
        namedTypes(stage)
        let id = try named(stage, "Bo Park", of: [FieldFixtures.namedEmployeeID], words: "Bo Park, joined in March.")
        stage.editor.selection = nil
        guard stage.editor.document[id]?[TitleProperty.self] == "Bo Park" else { throw GalleryFailure("titled through Person's") }
        return canvas(stage)
    },
    GalleryState("title-by-hand", "the same note titled by hand (`Annie`): its pill beside the chip, as any title's", size: single) { stage in
        namedTypes(stage)
        let id = try named(stage, "Ann Lee", of: [FieldFixtures.namedPersonID], words: "Ann Lee, staff engineer since 2021.")
        stage.editor.transact("Rename") { $0.update(id) { $0[TitleProperty.self] = "Annie" } }
        stage.editor.selection = nil
        guard stage.editor.adornmentFrames(of: id).contains(where: { $0.adornment == .of(TitlePill.self) }) else { throw GalleryFailure("a pill") }
        return canvas(stage)
    },
    GalleryState("title-cover", "zoomed out: the cover says the name over the bars, as it does for any title", size: single) { stage in
        namedTypes(stage)
        try named(stage, "Ann Lee", of: [FieldFixtures.namedPersonID], words: "Ann Lee, staff engineer since 2021.", size: CGSize(width: 900, height: 700))
        stage.editor.selection = nil
        return canvas(stage, zoom: 0.3)
    },
    GalleryState("title-folded", "a Staff of twelve fields: `from Person` holds the name, and there is still no pill", size: tall) { stage in
        namedTypes(stage)
        let type = stage.editor.put(staff, at: CGPoint(x: 3000, y: 3400))
        stage.editor.addTypeLink(FieldFixtures.namedPersonID, to: type)
        let id = try named(stage, "Cy Day", of: [staff.id], words: "Cy Day, on the desk by the window.", size: CGSize(width: 200, height: 160))
        stage.editor.selection = nil
        guard stage.editor.document[id]?[TitleProperty.self] == "Cy Day" else { throw GalleryFailure("titled through Person's") }
        return canvas(stage)
    },
    GalleryState("title-warning", "a type whose `$title` names a field it has none of (`nme`): the type's panel says so on its Issues tab", size: CGSize(width: 320, height: 520)) { stage in
        let schema = #"{"type": "object", "properties": {"name": {"type": "string"}, "$title": {"x-canvas-from": "nme"}}}"#
        let id = stage.editor.put((rowsTypeID(73), "Person", "A person has a name. The name is its title.", schema), at: CGPoint(x: 60, y: 40))
        return .image(try stage.issuesPicture(of: id, size: CGSize(width: 320, height: 520)))
    },
]
