import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import DetailPanel
import Foundation
import Locking
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import SwiftUI
import TestKit
import Titles
import Types

// Values in the panel (slice 10, the writer's: the Fields section): the states of one track, added to
// `galleryStates` (GalleryTypesLook.swift) as `panelStates`. The board's types are the shared fixtures (`FieldFixtures`, fixed
// ids and texts), so a state looks the same in the rows, the card, the panel and here.

extension GalleryStage {
    /// The panel of `id`, selected, on its Types tab, as an unshown window draws it at 2x in this appearance.
    func panelPicture(of id: ShapeID, tab: DetailTabID = .of(TypesTab.self), size: CGSize = CGSize(width: 320, height: 520)) throws -> NSBitmapImageRep {
        let record = try require(editor.document[id])
        try require(editor.detailPanel).choose(tab, for: record.kind)
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
        // The panel draws no ground of its own (the window's is under it in the app): filled here, so a dark picture
        // is light text on the dark window and not on nothing.
        appearance.performAsCurrentDrawingAppearance {
            if let graphics = NSGraphicsContext(bitmapImageRep: rep) {
                graphics.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
                graphics.cgContext.fill(CGRect(origin: .zero, size: size))
                graphics.flushGraphics()
            }
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        return rep
    }

    /// The fixtures' types as notes down the right of the stage, Employee a Person.
    func addFieldTypes(_ types: [FieldFixtures.TypeText]) {
        for (place, type) in types.enumerated() {
            editor.addTypeNote(type.schema, text: .init(plain: type.words), title: type.title,
                               frame: CGRect(x: 400, y: 20 + CGFloat(place) * 70, width: 120, height: 60), id: type.id)
        }
    }

    /// A note that is each of `types`.
    func addInstance(_ text: String, of types: [ShapeID]) -> ShapeID {
        let id = editor.add(StickyNote(frame: CGRect(x: 40, y: 40, width: 200, height: 160), text: .init(plain: text)), title: text)
        for type in types { editor.addTypeLink(type, to: id) }
        return id
    }
}

private let friendship: FieldFixtures.TypeText = (ShapeID(UUID(uuidString: "0E5B1A08-0000-4000-8000-0000000000A8")!), "Friendship", "A friendship is since when, and whether it is close.",
                                                  #"{"type": "object", "properties": {"since": {"type": "number"}, "close": {"type": "boolean"}}}"#)

/// A type of sixty number fields, `field1` to `field60`.
private let sixty: FieldFixtures.TypeText = (ShapeID(UUID(uuidString: "0E5B1A09-0000-4000-8000-0000000000A9")!), "Sixty", "Sixty fields.",
                                             #"{"type": "object", "properties": {"# + (1...60).map { #""field\#($0)": {"type": "\#($0 % 3 == 0 ? "string" : "number")"}"# }.joined(separator: ", ") + "}}")

@MainActor
private func order(_ stage: GalleryStage, values: [(FieldPath, JSONValue)]) throws -> ShapeID {
    stage.addFieldTypes([FieldFixtures.person, FieldFixtures.address, FieldFixtures.order])
    let id = stage.addInstance("Order 1042", of: [FieldFixtures.orderID])
    for (path, value) in values { expect(try require(stage.editor.fieldWriter).set(value, at: path, of: id)) }
    return id
}

private let orderValues: [(FieldPath, JSONValue)] = [
    (FieldPath(field: "shippingAddress"), ["street": "12 Mill Lane", "city": "Leeds", "postcode": "LS1 4AB"]),
    (FieldPath(field: "lineItems"), [["product": "Plate", "quantity": 2, "price": 4.5], ["product": "Mug", "quantity": 1, "price": 6]]),
    (FieldPath(field: "status"), "paid"),
    (FieldPath(field: "tags"), ["kitchen", "gift"]),
    (FieldPath(field: "gift"), true),
]

@MainActor let panelStates: [GalleryState] = [
    GalleryState("Flow3-p4-arrow-fields", answers: "Flow3 p4", "an arrow that is a Friendship: its Types tab with the `Types` row and `FIELDS`: `since [2019]`, `close [x]`") { stage in
        stage.addFieldTypes([friendship])
        let arrow = stage.editor.add(Arrow(start: .free(CGPoint(x: 40, y: 300)), end: .free(CGPoint(x: 340, y: 300)), text: "friends"))
        stage.editor.addTypeLink(friendship.id, to: arrow)
        let writer = try require(stage.editor.fieldWriter)
        writer.setTyped("2019", as: .number(integer: false), at: FieldPath(field: "since"), of: arrow)
        writer.set(true, at: FieldPath(field: "close"), of: arrow)
        return .image(try stage.panelPicture(of: arrow, size: CGSize(width: 320, height: 260)))
    },
    GalleryState("Flow5-p2-order-panel", answers: "Flow5 p2", "the Order in the panel: customer, shipping address, line items, status paid, tags, gift ticked, gift note empty (a field with more in it is a summary line until the form lands)") { stage in
        .image(try stage.panelPicture(of: try order(stage, values: orderValues)))
    },
    GalleryState("fields-panel-every-kind", "one field of each kind the panel draws: text, number, date, yes or no, a choice, an either, and the lines for the rest") { stage in
        stage.addFieldTypes([FieldFixtures.person, FieldFixtures.address, FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        let id = stage.addInstance("Everything", of: [FieldFixtures.kindsAID, FieldFixtures.kindsBID])
        let writer = try require(stage.editor.fieldWriter)
        writer.set("Launch", at: FieldPath(field: "name"), of: id)
        writer.setTyped("9.50", as: .number(integer: false), at: FieldPath(field: "price"), of: id)
        writer.setTyped("3/3/26", as: .date, at: FieldPath(field: "due"), of: id)
        writer.set(true, at: FieldPath(field: "done"), of: id)
        writer.set("shipped", at: FieldPath(field: "status"), of: id)
        writer.set("12", at: FieldPath(field: "size"), of: id)
        return .image(try stage.panelPicture(of: id, size: CGSize(width: 320, height: 760)))
    },
    GalleryState("fields-panel-empty", "an Order with no values: every field blank") { stage in
        .image(try stage.panelPicture(of: try order(stage, values: [])))
    },
    GalleryState("fields-panel-unnamed", "a note that was a Person and is none: its values dimmed with a minus each, no header") { stage in
        stage.addFieldTypes([FieldFixtures.person])
        let id = stage.addInstance("Ann", of: [])
        let writer = try require(stage.editor.fieldWriter)
        writer.set("Ann Lee", at: FieldPath(field: "name"), of: id)
        writer.set("ann@acme.com", at: FieldPath(field: "email"), of: id)
        writer.set("Annie", at: FieldPath(field: "nickname"), of: id)
        return .image(try stage.panelPicture(of: id, size: CGSize(width: 320, height: 170)))
    },
    GalleryState("fields-panel-read-only", "a locked Order: boxes read-only and dimmed, the menu and checkbox off") { stage in
        let id = try order(stage, values: orderValues)
        stage.editor.lock([id])
        return .image(try stage.panelPicture(of: id))
    },
    GalleryState("fields-panel-many", "sixty fields, no fold: the panel scrolls", size: CGSize(width: 560, height: 360)) { stage in
        stage.addFieldTypes([sixty])
        let id = stage.addInstance("Many", of: [sixty.id])
        let writer = try require(stage.editor.fieldWriter)
        for place in stride(from: 1, through: 60, by: 7) { writer.set(place % 3 == 0 ? JSONValue.string("v\(place)") : JSONValue.number(Double(place)), at: FieldPath(field: "field\(place)"), of: id) }
        return .image(try stage.panelPicture(of: id, size: CGSize(width: 320, height: 700)))
    },
]
