import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Foundation
import Frames
import Mentions
import Neighbors
import Selection
import StickyNotes
import Subboards
import SwiftUI
import TestKit
import Titles
import Types

// The Connections tab of a shape's panel (Neighbors' lists): the states of one track, added to
// `galleryStates` (GalleryTypesLook.swift) as `connectionStates`. One small file of boards, the same in
// every state: a storefront's board, with a note that points, is pointed at, mentions and is mentioned.

extension GalleryStage {
    /// The panel of `id`, selected, on its Connections tab, once its lists have landed, as an unshown
    /// window draws it at 2x in this appearance. `prepare` runs with the lists landed (to fold one, to
    /// search them), and the panel is drawn after what it asked for has landed too.
    func connectionsPicture(of id: ShapeID, size: CGSize = CGSize(width: 300, height: 520), prepare: (NeighborList) -> Void = { _ in }) throws -> NSBitmapImageRep {
        let record = try require(editor.document[id])
        try require(editor.detailPanel).choose(.of(NeighborsTab.self), for: record.kind)
        editor.selection = id
        let host = NSHostingView(rootView: try require(editor.registry.hostInspector).view(for: editor, onExit: {}))
        host.frame = CGRect(origin: .zero, size: size)
        let panelWindow = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        panelWindow.contentView = host
        panelWindow.appearance = appearance
        panelWindow.settle()
        let list = try require(editor.neighborList)
        spinRunLoop(until: { list.subject == id && list.hasLanded && !list.isAsking })
        prepare(list)
        spin(0.05)
        spinRunLoop(until: { !list.isAsking })
        panelWindow.settle()
        spin(0.15)
        panelWindow.settle()
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        // The panel draws no ground of its own (the window's is under it in the app).
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
}

/// The shapes of the track's file: on the root, the Storefront subboard in the frame Q3, the
/// Payments subboard it points to, and two notes that mention shapes inside it; on Storefront's
/// board, the note Checkout flow in the frame Sprint 3, what it points to and what points to it.
@MainActor private struct Storefront {
    let storefront: ShapeID, checkout: ShapeID, toPayment: ShapeID

    init(_ stage: GalleryStage) throws {
        let editor = stage.editor
        editor.nameRoot("Roadmap")
        func bound(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        func note(_ title: String, _ x: CGFloat, _ y: CGFloat, _ text: MentionText = "") -> ShapeID {
            editor.add(StickyNote(frame: CGRect(x: x, y: y, width: 160, height: 120), text: text), title: title)
        }
        // The root.
        let quarter = editor.add(Frame(frame: CGRect(x: 0, y: 0, width: 700, height: 400)), title: "Q3")
        storefront = editor.add(Subboard(frame: CGRect(x: 40, y: 60, width: 240, height: 160)), title: "Storefront")
        let payments = editor.add(Subboard(frame: CGRect(x: 400, y: 60, width: 240, height: 160)), title: "Payments")
        editor.put([storefront, payments], in: quarter)
        editor.add(Arrow(start: bound(storefront), end: bound(payments)))
        _ = note("Launch plan", 40, 500, MentionText([.mention(storefront, label: "Storefront"), .text(" ships before "), .mention(payments, label: "Payments")]))
        // Storefront's board.
        let checkoutID = ShapeID()
        let risks = note("Risks", 300, 500, MentionText([.mention(checkoutID, label: "Checkout flow"), .text(" has no owner yet")]))
        _ = risks
        guard editor.showBoard(BoardID(owner: storefront)) else { throw GalleryFailure("the Storefront board can't be shown") }
        let sprint = editor.add(Frame(frame: CGRect(x: 0, y: 0, width: 900, height: 500)), title: "Sprint 3")
        let ann = note("Ann Lee", 660, 320)
        var record = ShapeRecord(id: checkoutID, StickyNote(frame: CGRect(x: 300, y: 160, width: 200, height: 160),
                                                            text: MentionText([.text("Owner: "), .mention(ann, label: "Ann Lee")])))
        record[TitleProperty.self] = "Checkout flow"
        editor.transact { $0.insert(record) }
        checkout = checkoutID
        let payment = note("Payment API", 660, 40)
        let refunds = editor.add(Subboard(frame: CGRect(x: 620, y: 180, width: 240, height: 120)), title: "Refunds")
        let cart = note("Cart", 40, 40)
        let launch = note("Launch notes", 40, 320, MentionText([.text("We are blocked on "), .mention(checkoutID, label: "Checkout flow"), .text(" until the payment contract is signed")]))
        _ = launch
        editor.put([checkout, payment, refunds, cart, ann], in: sprint)
        toPayment = editor.add(Arrow(start: bound(checkout), end: bound(payment)))
        editor.add(Arrow(start: bound(checkout), end: bound(refunds)))
        editor.add(Arrow(start: bound(cart), end: bound(checkout)))
        stage.spin()
    }
}

@MainActor let connectionStates: [GalleryState] = [
    GalleryState("connections-note", "a note's Connections tab: Points To (a note, a subboard), Pointed To By, Mentions, Mentioned By with each mentioner's text around its mention and the board of the one on another board, Inside (the subboard, then the frame)") { stage in
        let scene = try Storefront(stage)
        return .image(try stage.connectionsPicture(of: scene.checkout))
    },
    GalleryState("connections-subboard", "a subboard's: a strip of two tabs, Board and Connections; Points To, Mentioned By, Inside its frame, and Contains, its board's shapes that are in no frame, and the frame") { stage in
        let scene = try Storefront(stage)
        stage.editor.goBack()
        if stage.editor.board != .root { _ = stage.editor.showBoard(.root) }
        return .image(try stage.connectionsPicture(of: scene.storefront))
    },
    GalleryState("connections-arrow", "an arrow's: where it ends under Points To, where it starts under Pointed To By, and the frame it's in") { stage in
        let scene = try Storefront(stage)
        return .image(try stage.connectionsPicture(of: scene.toPayment, size: CGSize(width: 300, height: 260)))
    },
    GalleryState("connections-folded", "the note's with Points To and Mentioned By folded: each head with its count, no rows") { stage in
        let scene = try Storefront(stage)
        return .image(try stage.connectionsPicture(of: scene.checkout) { list in
            list.setFolded(0, true)
            list.setFolded(3, true)
        })
    },
    GalleryState("connections-type", "a type's: Pointed To By (the relationship type at it), Instances (what is of it: one on the board shown, two on a subboard's board with its name) and Inside, its frame") { stage in
        .image(try stage.connectionsPicture(of: try tableType(stage), size: CGSize(width: 300, height: 320)))
    },
    GalleryState("connections-untitled", "notes with no titles, as most are: each row is the note's text on one line, cut to the row; an empty one is Empty Note") { stage in
        .image(try stage.connectionsPicture(of: untitledNotes(stage), size: CGSize(width: 300, height: 260)))
    },
    GalleryState("connections-none", "a note nothing is connected to, on the root in no frame: No Connections") { stage in
        let id = stage.editor.add(StickyNote(frame: CGRect(x: 40, y: 40, width: 200, height: 160), text: "Alone"), title: "Alone")
        return .image(try stage.connectionsPicture(of: id, size: CGSize(width: 300, height: 200)))
    },
    GalleryState("connections-long", "a note thirty notes mention: the search field over the lists, every row there (the panel scrolls)") { stage in
        .image(try stage.connectionsPicture(of: try hub(stage)))
    },
    GalleryState("connections-search", "the same, searched for `al`: the notes whose names match, the best first, the count of what matched") { stage in
        .image(try stage.connectionsPicture(of: try hub(stage)) { $0.setSearch("al") })
    },
    GalleryState("connections-search-none", "the same, searched for something no row is called: No Matches") { stage in
        .image(try stage.connectionsPicture(of: try hub(stage), size: CGSize(width: 300, height: 200)) { $0.setSearch("zzz") })
    },
]

/// The type Table in the frame Types, with the relationship type owns pointing at it, and what is of Table:
/// orders on the root, and users and carts on the Commerce modules subboard's board. The root is shown.
@MainActor private func tableType(_ stage: GalleryStage) throws -> ShapeID {
    let editor = stage.editor
    func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
    func instance(_ title: String, _ x: CGFloat, of type: ShapeID) {
        var record = ShapeRecord(StickyNote(frame: CGRect(x: x, y: 400, width: 160, height: 120)))
        record[TitleProperty.self] = title
        record[IsAProperty.self] = [TypeLink(type)]
        editor.transact { $0.insert(AnyShapeRecord(record)) }
    }
    let types = editor.add(Frame(frame: CGRect(x: 0, y: 0, width: 640, height: 300)), title: "Types")
    // A type's id is its color: fixed, as every state's are.
    let table = editor.addTypeNote(TypeSchemaProperty.starter, title: "Table", frame: CGRect(x: 40, y: 60, width: 200, height: 160),
                                   id: ShapeID(UUID(uuidString: "0E5B1A61-0000-4000-8000-0000000000C1")!))
    let owns = editor.addTypeNote(TypeSchemaProperty.starter, title: "owns", frame: CGRect(x: 400, y: 60, width: 200, height: 160),
                                  id: ShapeID(UUID(uuidString: "0E5B1A62-0000-4000-8000-0000000000C2")!))
    editor.transact { $0.update(owns) { $0[RelationshipProperty.self] = true } }
    editor.put([table, owns], in: types)
    editor.add(Arrow(start: bound(owns), end: bound(table)))
    instance("orders", 40, of: table)
    let modules = editor.add(Subboard(frame: CGRect(x: 400, y: 400, width: 240, height: 160)), title: "Commerce modules")
    guard editor.showBoard(BoardID(owner: modules)) else { throw GalleryFailure("the Commerce modules board can't be shown") }
    instance("users", 40, of: table)
    instance("carts", 240, of: table)
    guard editor.showBoard(.root) else { throw GalleryFailure("the root can't be shown") }
    stage.spin()
    return table
}

/// A note thirty named notes mention.
@MainActor private func hub(_ stage: GalleryStage) throws -> ShapeID {
    let names = ["Alpha", "Albatross", "Balance", "Catalog", "Delta", "Echo", "Falcon", "Gallery", "Halo", "Index", "Journal", "Kestrel", "Ledger",
                 "Malt", "Nectar", "Opal", "Portal", "Quill", "Royal", "Salt", "Talon", "Umbral", "Valve", "Walnut", "Xenial", "Yield", "Zeal",
                 "Final call", "Signal", "Alto"]
    let hub = stage.editor.add(StickyNote(frame: CGRect(x: 40, y: 40, width: 200, height: 160), text: "Hub"), title: "Hub")
    for (place, name) in names.enumerated() {
        let text = MentionText([.text("See "), .mention(hub, label: "Hub")])
        stage.editor.add(StickyNote(frame: CGRect(x: 300 + CGFloat(place % 6) * 180, y: CGFloat(place / 6) * 140, width: 160, height: 120), text: text), title: name)
    }
    stage.spin()
    return hub
}

/// A note with no title that points to two others and is pointed to by an empty one.
@MainActor private func untitledNotes(_ stage: GalleryStage) -> ShapeID {
    let editor = stage.editor
    func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
    func plain(_ text: String, _ x: CGFloat, _ y: CGFloat) -> ShapeID {
        editor.add(StickyNote(frame: CGRect(x: x, y: y, width: 200, height: 160), text: .init(plain: text)))
    }
    let idea = plain("Ship the importer first", 300, 220)
    let parser = plain("Parser handles quoted commas\nand embedded newlines, which the old one never did", 40, 20)
    let data = plain("Ask Dana about the staging data", 580, 20)
    let empty = plain("", 580, 420)
    editor.add(Arrow(start: bound(idea), end: bound(parser)))
    editor.add(Arrow(start: bound(idea), end: bound(data)))
    editor.add(Arrow(start: bound(empty), end: bound(idea)))
    stage.spin()
    return idea
}
