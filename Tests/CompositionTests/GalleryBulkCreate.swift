import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import SlashCommands
import StickyNotes
import TestKit
import TextEditing

// `/bulk-create`: the states of one track, added to `galleryStates` (GalleryTypesLook.swift) as `bulkCreateStates`,
// one for each wireframe of its plan (the working doc "Bulk create"), on an empty board at 50%: `/` and its list,
// the line typed, the notes waiting on the pointer in a column, ⌥'s row, the three put down and selected, and the
// pointer off the canvas, the column in the middle of the view; then the column waiting zoomed out, its titles on it.

private let bulkStage = CGSize(width: 1000, height: 620)

extension GalleryStage {
    /// `/bulk-create Auth, Billing, Payments` typed and run on an empty board at `zoom`: three notes waiting.
    fileprivate func waitingNotes(zoom: CGFloat = 0.5) throws {
        look(at: .zero, zoom: zoom)
        _ = try openBar(on: [], typing: "bulk-create Auth, Billing, Payments")
        window.pressReturn()
        window.settle()
        guard editor.isPlacingLater else { throw GalleryFailure("bulk-create left nothing waiting") }
    }
}

@MainActor let bulkCreateStates: [GalleryState] = [
    GalleryState("Bulk1-list", answers: "1", "`/` on an empty board, `bu` typed: the bar at the top, its one row `bulk-create` and its hint", size: bulkStage) { stage in
        stage.look(at: .zero, zoom: 0.5)
        return .image(try stage.pictureWithBarList(try stage.openBar(on: [], typing: "bu")))
    },
    GalleryState("Bulk2-line", answers: "2", "the line typed: `/bulk-create` marked, the titles marked lighter", size: bulkStage) { stage in
        stage.look(at: .zero, zoom: 0.5)
        _ = try stage.openBar(on: [], typing: "bulk-create Auth, Billing, Payments")
        return .image(stage.picture())
    },
    GalleryState("Bulk3-column", answers: "3", "Return: the bar gone, the three notes faint on the pointer in a column, the first's middle on it", size: bulkStage) { stage in
        try stage.waitingNotes()
        stage.hover(at: CGPoint(x: 330, y: 200))
        return .image(stage.picture())
    },
    GalleryState("Bulk4-row", answers: "4", "⌥ held: a row, swung around the first note", size: bulkStage) { stage in
        try stage.waitingNotes()
        stage.hover(at: CGPoint(x: 330, y: 200))
        stage.editor.modifiersChanged(held: .option)
        return .image(stage.picture())
    },
    GalleryState("Bulk5-placed", answers: "5", "a click: the three put down where they were drawn, all selected", size: bulkStage) { stage in
        try stage.waitingNotes()
        stage.press(at: CGPoint(x: 330, y: 200))
        stage.release(at: CGPoint(x: 330, y: 200))
        stage.window.settle()
        return .image(stage.picture())
    },
    GalleryState("Bulk6-keys", answers: "6", "the pointer off the canvas: the column in the middle of the view, where Return puts it", size: bulkStage) { stage in
        try stage.waitingNotes()
        return .image(stage.picture())
    },
    GalleryState("Bulk7-zoomed-out", answers: "-", "at 25%: the column waiting as skeletons, each title on its note, faint", size: bulkStage) { stage in
        try stage.waitingNotes(zoom: 0.25)
        stage.hover(at: CGPoint(x: 330, y: 160))
        return .image(stage.picture())
    },
]
