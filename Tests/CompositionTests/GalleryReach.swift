import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import Foundation
import Mentions
import Neighbors
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// The whole reach on hover (Neighbors, [neighbors](.claude/rules/neighbors.md)): the cold first minute of
// View › Show Whole Reach, the states of one track, added to `galleryStates` (GalleryTypesLook.swift) as
// `reachStates`. One board, the same in every state: an order that fans out to three, two of which meet at
// one, four hops deep, a cycle back into it, and what leads into it for ⌥.

@MainActor private struct Orders {
    let orders: ShapeID, pricing: ShapeID
    /// What the reach lights going down: the notes by hop.
    let downstream: [Set<ShapeID>]

    init(_ stage: GalleryStage) {
        let editor = stage.editor
        func bound(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        func note(_ title: String, _ column: Int, _ row: Double) -> ShapeID {
            editor.add(StickyNote(frame: CGRect(x: CGFloat(column) * 190, y: CGFloat(row) * 100, width: 130, height: 60), text: MentionText(stringLiteral: title)),
                       title: title)
        }
        func arrow(_ from: ShapeID, _ to: ShapeID) { editor.add(Arrow(start: bound(from), end: bound(to))) }
        // Four hops down, a fan-out of three, a diamond (Ledger), a cycle (Archive back to Orders and to Validate).
        orders = note("Orders", 2, 2)
        let intake = note("Intake", 1, 2), web = note("Web", 0, 1), mobile = note("Mobile", 0, 3), partner = note("Partner", 1, 0.4)
        let validate = note("Validate", 3, 0.5), price = note("Pricing", 3, 2), stock = note("Stock", 3, 3.5)
        let ledger = note("Ledger", 4, 1.2), warehouse = note("Warehouse", 4, 3.5)
        let reports = note("Reports", 5, 1.2), pick = note("Pick list", 5, 3.5)
        let archive = note("Archive", 6, 0.2)
        _ = note("Billing", 0, 4.5)
        pricing = price
        for (from, to) in [(web, intake), (mobile, intake), (intake, orders), (partner, orders),
                           (orders, validate), (orders, price), (orders, stock),
                           (validate, ledger), (price, ledger), (stock, warehouse),
                           (ledger, reports), (warehouse, pick), (reports, archive), (archive, orders), (archive, validate)] { arrow(from, to) }
        downstream = [[validate, price, stock], [ledger, warehouse], [reports, pick], [archive]]
        stage.look(at: CGPoint(x: -30, y: -40), zoom: 0.78)
        stage.spin(0.05)
        // The camera's rest: a frame within `Style.dimCameraRest` of a camera change leaves the dim out.
        stage.scheduler.advance(by: .milliseconds(150))
    }
}

/// How much is lit, and how much is dimmed, on the stage's board now.
@MainActor private struct Lit {
    let shapes: Int, arrows: Int, dim: Bool
    init(_ stage: GalleryStage) {
        let outlines = stage.editor.outlines
        var shapes = Set<ShapeID>()
        for group in outlines.tinted { shapes.formUnion(group.shapes) }
        let arrows = shapes.filter { stage.editor.document[$0]?.kind == Arrow.kind }
        self.shapes = shapes.count - arrows.count
        self.arrows = arrows.count
        dim = outlines.dim != nil
    }
}

private extension GalleryStage {
    /// The pointer on `id` (⌥ held with `up`), once both answers have landed: hop 1 alone, no dim.
    func hover(_ id: ShapeID, upstream: Bool = false) {
        editor.modifiersChangedInWindow(held: upstream ? .option : [])
        editor.hovered = id
        scheduler.advance(by: .zero)
        if let reach = editor.reach { _ = spinRunLoop(until: { !reach.isAsking }) }
    }

    /// Rested and the pulse run out.
    func settle() {
        scheduler.advance(by: .milliseconds(600))
        spin(0.05)
    }

    func reachPicture(_ body: (Orders) -> Void) throws -> GalleryOutput {
        let scene = Orders(self)
        body(scene)
        return .image(picture())
    }
}

@MainActor let reachStates: [GalleryState] = [
    GalleryState("reach-1-menu", "the View menu with Show Whole Reach checked, after Show Minimap", isText: true, reach: true) { stage in
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: stage.editor.registry)
        let view = try require(menus.main.item(withTitle: "View")?.submenu)
        for item in view.items { if let command = BoardMenus.command(of: item) { item.state = (stage.editor.isChecked(command) ?? false) ? .on : .off } }
        return .text(view.outline.joined(separator: "\n"))
    },
    GalleryState("reach-2-hover", "Orders hovered, the pointer not yet at rest: its three next steps ringed at full strength, the board not dimmed", size: CGSize(width: 1_080, height: 560), reach: true) { stage in
        try stage.reachPicture { scene in
            stage.hover(scene.orders)
            let lit = Lit(stage)
            expect(lit.shapes == 3 && !lit.dim, "hop 1 only, no dim: \(lit)")
        }
    },
    GalleryState("reach-3-rested", "Orders at rest: everything downstream ringed, each ring thinner and fainter by its hop, the rest of the board dimmed, the arrows it travels lit", size: CGSize(width: 1_080, height: 560), reach: true) { stage in
        try stage.reachPicture { scene in
            stage.hover(scene.orders)
            stage.settle()
            let lit = Lit(stage)
            expect(lit.shapes == 8 && lit.dim, "the eight downstream, the board dimmed: \(lit)")
        }
    },
    GalleryState("reach-4-upstream", "Orders at rest with ⌥ held: what leads into it, ringed in the upstream color: Intake, Partner and Archive (the cycle's way back) at full strength, then Web, Mobile, Reports and on, each fainter", size: CGSize(width: 1_080, height: 560), reach: true) { stage in
        try stage.reachPicture { scene in
            stage.hover(scene.orders, upstream: true)
            stage.settle()
            let lit = Lit(stage)
            expect(lit.shapes >= 4 && lit.dim, "the upstream four or more, dimmed: \(lit)")
        }
    },
    GalleryState("reach-5-pulse-0ms", "the pulse as the pointer comes to rest, 0 ms: hop 1 and nothing past it", size: CGSize(width: 1_080, height: 560), reach: true) { stage in
        try stage.reachPicture { scene in stage.pulse(scene, after: 0) }
    },
    GalleryState("reach-5-pulse-80ms", "the pulse at 80 ms: the second hop arriving", size: CGSize(width: 1_080, height: 560), reach: true) { stage in
        try stage.reachPicture { scene in stage.pulse(scene, after: 80) }
    },
    GalleryState("reach-5-pulse-160ms", "the pulse at 160 ms: the third hop arriving", size: CGSize(width: 1_080, height: 560), reach: true) { stage in
        try stage.reachPicture { scene in stage.pulse(scene, after: 160) }
    },
    GalleryState("reach-5-pulse-320ms", "the pulse at 320 ms: every hop, settled", size: CGSize(width: 1_080, height: 560), reach: true) { stage in
        try stage.reachPicture { scene in stage.pulse(scene, after: 320) }
    },
    GalleryState("reach-6-sweep", "the pointer moved from Orders to Pricing: the dim kept, only Pricing's next step ringed until it rests", size: CGSize(width: 1_080, height: 560), reach: true) { stage in
        try stage.reachPicture { scene in
            stage.hover(scene.orders)
            stage.settle()
            stage.hover(scene.pricing)
            let lit = Lit(stage)
            expect(lit.shapes == 1 && lit.dim, "Pricing's hop 1 alone under the kept dim: \(lit)")
        }
    },
]

private extension GalleryStage {
    /// Orders hovered and rested, `ms` into the pulse.
    func pulse(_ scene: Orders, after ms: Int) {
        hover(scene.orders)
        scheduler.advance(by: .milliseconds(150))
        spin(0.05)
        scheduler.advance(by: .milliseconds(ms))
    }
}
