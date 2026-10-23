import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import Frames
import Mentions
import Selection
import StickyNotes
import Subboards
import TestKit
import Titles

// The `@` picker's rows for shapes of one name in different containers, and the rows of the lists that name a shape (slice
// lists): states of one track, added to `galleryStates` as `placeStates`.

@MainActor private func titledNote(_ title: String, at point: CGPoint, in container: ShapeID? = nil, id: ShapeID = ShapeID()) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id, StickyNote(frame: CGRect(origin: point, size: CGSize(width: 160, height: 100)), text: MentionText(plain: title))))
    record[TitleProperty.self] = title
    return record.copy(as: id, container: container)
}

@MainActor private func titledFrame(_ title: String?, _ rect: CGRect, in container: ShapeID? = nil, id: ShapeID = ShapeID()) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id, Frame(frame: rect)))
    record[TitleProperty.self] = title
    return record.copy(as: id, container: container)
}

/// Two Checkouts in two frames (one in a frame in a frame), one in a subboard, a note named for both words on the root, and an untitled frame's; the
/// text is in a new note.
@MainActor private func placesBoard(_ stage: GalleryStage, query: String) throws -> GalleryOutput {
    let alpha = ShapeID(), beta = ShapeID(), gamma = ShapeID(), annex = ShapeID(), blank = ShapeID(), text = ShapeID()
    var subboard = AnyShapeRecord(ShapeRecord(id: annex, Subboard(frame: CGRect(x: 700, y: 520, width: 200, height: 120))))
    subboard[TitleProperty.self] = "Annex"
    let root = CanvasDocument(shapes: [
        titledFrame("Alpha", CGRect(x: 20, y: 20, width: 330, height: 300), id: alpha), titledFrame("Beta", CGRect(x: 380, y: 20, width: 200, height: 160), id: beta),
        titledFrame("Gamma", CGRect(x: 40, y: 150, width: 290, height: 150), in: alpha, id: gamma), titledFrame(nil, CGRect(x: 380, y: 200, width: 200, height: 120), id: blank),
        titledNote("Checkout", at: CGPoint(x: 40, y: 50), in: alpha), titledNote("Checkout", at: CGPoint(x: 400, y: 50), in: beta),
        titledNote("Checkout", at: CGPoint(x: 60, y: 170), in: gamma), titledNote("Checkout", at: CGPoint(x: 400, y: 220), in: blank),
        titledNote("Alpha checkout notes", at: CGPoint(x: 620, y: 40)), subboard,
        titledNote("", at: CGPoint(x: 620, y: 300), id: text),
    ])
    stage.editor.replaceFile(with: CanvasFile(root: root, children: [annex: CanvasDocument(shapes: [titledNote("Checkout", at: CGPoint(x: 40, y: 40))])]))
    stage.editor.selection = nil
    stage.look(at: .zero)
    let view = try stage.edit(text)
    stage.window.type("@" + query)
    guard view.picker != nil else { throw GalleryFailure("the picker is open") }
    // The picker is the view's caret list (the slash commands' is another).
    let caret = view.firstRect(forCharacterRange: NSRange(location: view.selectedRange().location, length: 0), actualRange: nil)
    return .image(try stage.pictureWithList(stage.listRows(in: view.caretListWindow), below: stage.window.convertFromScreen(caret)))
}

@MainActor let placeStates: [GalleryState] = [
    GalleryState("places-picker-checkout", "the `@` picker for `checkout`: notes of one name in frames, a frame in a frame, an untitled frame and a subboard; each row says its path",
                 size: CGSize(width: 940, height: 680)) { stage in
        try placesBoard(stage, query: "checkout")
    },
    GalleryState("places-picker-alpha-check", "the `@` picker for `alpha check`: the name's strong match, then the notes found by their frames",
                 size: CGSize(width: 940, height: 680)) { stage in
        try placesBoard(stage, query: "alpha check")
    },
]

/// Two Checkouts, one in a frame three deep with long names, and a short path: how the longest is cut in the picker's width.
@MainActor private func longPathBoard(_ stage: GalleryStage, query: String) throws -> GalleryOutput {
    let roadmap = ShapeID(), sprint = ShapeID(), backlog = ShapeID(), text = ShapeID()
    let root = CanvasDocument(shapes: [
        titledFrame("Quarterly roadmap", CGRect(x: 20, y: 20, width: 700, height: 400), id: roadmap),
        titledFrame("Sprint planning", CGRect(x: 40, y: 60, width: 640, height: 330), in: roadmap, id: sprint),
        titledFrame("Backlog grooming", CGRect(x: 60, y: 100, width: 600, height: 260), in: sprint, id: backlog),
        titledNote("Checkout", at: CGPoint(x: 80, y: 140), in: backlog), titledNote("Checkout", at: CGPoint(x: 800, y: 40)),
        titledNote("", at: CGPoint(x: 800, y: 300), id: text),
    ])
    stage.editor.replaceFile(with: CanvasFile(root: root))
    stage.editor.selection = nil
    stage.look(at: .zero)
    let view = try stage.edit(text)
    stage.window.type("@" + query)
    guard view.picker != nil else { throw GalleryFailure("the picker is open") }
    let caret = view.firstRect(forCharacterRange: NSRange(location: view.selectedRange().location, length: 0), actualRange: nil)
    return .image(try stage.pictureWithList(stage.listRows(in: view.caretListWindow), below: stage.window.convertFromScreen(caret)))
}

@MainActor let longPlaceStates: [GalleryState] = [
    GalleryState("places-picker-long-checkout", "the `@` picker for `checkout`: a note three frames deep with long names, and one on the board", size: CGSize(width: 1000, height: 480)) { stage in
        try longPathBoard(stage, query: "checkout")
    },
]
