import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
import Foundation
import Geometry
import References
import Selection
import TestKit
import Titles
import Types

// Mirrors (issue 24, look A): a reference's pill expanded into its original drawn again under it, as the wireframes'
// boards show them. Files `Mirror-*`.

private let orderSchema = #""{\"type\": \"object\", \"properties\": {\"total\": {\"type\": \"number\"}, \"status\": {\"type\": \"string\", \"enum\": [\"open\", \"paid\"]}, \"customer\": {\"type\": \"string\"}}}""#

extension GalleryStage {
    /// The reference on the board shown that stands for `title`.
    func pill(for title: String) throws -> ShapeID {
        let target = try shape(title)
        let found = editor.document.shapes.first { ($0.props as? Reference)?.target?.id == target }
        let labels = editor.document.shapes.compactMap { ($0.props as? Reference)?.target?.label }
        return try require(found?.id, "no pill for \(title) among \(labels) on \(editor.board)")
    }

    /// Expands the pills for these titles into mirrors.
    func expand(_ titles: [String]) throws {
        let pills = try titles.map { try pill(for: $0) }
        editor.perform(.expandReference, on: pills)
        settlePills()
    }
}

/// Policies holds Pricing rules in its Pricing frame; Checkout's Confirm points at it through a pill, which Checkout shows.
@MainActor func mirrorCheckout(_ stage: GalleryStage) throws {
    try stage.run("""
    subboard "Policies" size: 200x100
    subboard "Checkout" right of "Policies" size: 200x100
    """)
    try stage.run(#"frame "Pricing" in "Policies" size: 520x360"#)
    try stage.run(#"sticky-note "Pricing rules" in "Pricing" text: "Free shipping over $50. Coupons don't stack. Tax after discounts." size: 260x180"#)
    try stage.run(#"sticky-note "Confirm" in "Checkout" text: "Receipt and email" size: 200x120"#)
    try stage.show(try stage.board(of: "Checkout"))
    try stage.run(#"edge "Confirm" -> "Pricing rules" via: reference from: bottom"#)
    stage.editor.selection = nil
}

/// Every kind a mirror shows: a type, a note of it, a subboard and a frame with notes, on Policies; their pills on Checkout.
@MainActor func mirrorKinds(_ stage: GalleryStage) throws {
    try stage.run("""
    subboard "Policies" size: 200x100
    subboard "Checkout" right of "Policies" size: 200x100
    """)
    try stage.run("""
    sticky-note "Order" in "Policies" color: purple schema: \(orderSchema) text: "An order has a total, a status and a customer." size: 260x180
    sticky-note "Order #1042" in "Policies" right of "Order" is: "Order" fieldValues: {"total": 120, "status": "paid", "customer": "Ann Lee"} size: 260x180
    subboard "Stripe" in "Policies" right of "Order #1042" size: 200x120
    frame "Refunds" in "Policies" below "Order" color: green size: 560x260
    """)
    try stage.run("""
    sticky-note "Refund window" in "Refunds" text: "Thirty days" size: 180x100
    sticky-note "Retry" in "Refunds" right of "Refund window" text: "Retry the refund" size: 180x100
    """)
    try stage.show(try stage.board(of: "Checkout"))
    try stage.run(#"sticky-note "Anchor" size: 120x60"#)
    try stage.run("""
    edge "Anchor" -> "Order" via: reference
    edge "Anchor" -> "Order #1042" via: reference
    edge "Anchor" -> "Stripe" via: reference
    edge "Anchor" -> "Refunds" via: reference channel: none
    """)
    stage.editor.selection = nil
}

/// Lays the mirrors out in a row, side by side, each its laid-out frame and `gap` from the one before, below the anchor.
@MainActor private func row(_ stage: GalleryStage, _ titles: [String], at origin: CGPoint, gap: CGFloat = 40) throws {
    var x = origin.x
    for title in titles {
        let id = try stage.pill(for: title)
        let inset = (stage.editor.document[id]?.box?.minX ?? 0) - (stage.editor.shapeContext.frame(of: id)?.minX ?? 0)
        stage.editor.transact("Place") { $0.update(id, as: Reference.self) { $0.props.frame.origin = CGPoint(x: x + inset, y: origin.y) } }
        stage.settlePills()
        x = (stage.editor.shapeContext.frame(of: id)?.maxX ?? x) + gap
    }
    let anchor = try stage.shape("Anchor")
    stage.editor.transact("Place") { $0.update(anchor) { $0.box?.origin = CGPoint(x: origin.x, y: origin.y - 160) } }
    stage.settlePills()
}

@MainActor let referenceMirrorStates: [GalleryState] = [
    GalleryState("Mirror-1-note", "Checkout's Confirm and its pill for Pricing rules, expanded: the pill on top, the note quieted under it",
                 size: CGSize(width: 900, height: 620)) { stage in
        try mirrorCheckout(stage)
        try stage.expand(["Pricing rules"])
        try stage.look(at: "Confirm", inset: CGPoint(x: 60, y: 40))
        return .image(stage.picture())
    },
    GalleryState("Mirror-2-kinds", "a type, a note of it, a subboard and a frame, each as a mirror", size: CGSize(width: 1400, height: 760)) { stage in
        try mirrorKinds(stage)
        try stage.expand(["Order", "Order #1042", "Stripe", "Refunds"])
        try row(stage, ["Order", "Order #1042", "Stripe", "Refunds"], at: CGPoint(x: 0, y: 200))
        stage.look(at: CGPoint(x: -40, y: 160))
        return .image(stage.picture())
    },
    GalleryState("Mirror-3-typing", "a double-click on the body types in Pricing rules: the note's own editor over it, at full color",
                 size: CGSize(width: 900, height: 620)) { stage in
        try mirrorCheckout(stage)
        try stage.expand(["Pricing rules"])
        try stage.look(at: "Confirm", inset: CGPoint(x: 60, y: 40))
        let mirror = try stage.pill(for: "Pricing rules")
        let frame = try require(stage.editor.shapeContext.frame(of: mirror))
        let point = stage.viewPoint(CGPoint(x: frame.midX, y: frame.maxY - 30))
        stage.press(at: point)
        stage.release(at: point)
        stage.editor.pointerDown(PointerEvent(location: point, timestamp: 4, clickCount: 2))
        stage.editor.pointerUp(PointerEvent(location: point, timestamp: 5, clickCount: 2))
        stage.window.settle()
        stage.window.type(" Gift cards never expire.")
        stage.window.settle()
        return .image(stage.picture())
    },
    GalleryState("Mirror-4-selected", "the mirror selected: one shape, handles at its corners", size: CGSize(width: 900, height: 620)) { stage in
        try mirrorCheckout(stage)
        try stage.expand(["Pricing rules"])
        try stage.look(at: "Confirm", inset: CGPoint(x: 60, y: 40))
        stage.editor.selection = try stage.pill(for: "Pricing rules")
        stage.settlePills()
        return .image(stage.picture())
    },
    GalleryState("Mirror-5-deleted", "Pricing rules deleted: the mirror falls back to the dashed pill", size: CGSize(width: 900, height: 620)) { stage in
        try mirrorCheckout(stage)
        try stage.expand(["Pricing rules"])
        let note = try stage.shape("Pricing rules")
        stage.editor.transact("Delete") { $0.delete(inFile: [note]) }
        stage.settlePills()
        try stage.look(at: "Confirm", inset: CGPoint(x: 60, y: 40))
        return .image(stage.picture())
    },
    GalleryState("Mirror-6-zoomed-out", "the mirrors of every kind at 30%", size: CGSize(width: 900, height: 420)) { stage in
        try mirrorKinds(stage)
        try stage.expand(["Order", "Order #1042", "Stripe", "Refunds"])
        try row(stage, ["Order", "Order #1042", "Stripe", "Refunds"], at: CGPoint(x: 0, y: 200))
        stage.look(at: CGPoint(x: -100, y: 100), zoom: 0.3)
        return .image(stage.picture())
    },
    GalleryState("Mirror-7-menu", "the pill's menu: Expand right under Go to Original; a mirror's: Collapse", isText: true) { stage in
        try mirrorCheckout(stage)
        try stage.look(at: "Confirm", inset: CGPoint(x: 60, y: 40))
        let pill = try stage.pill(for: "Pricing rules")
        let box = try require(stage.editor.document[pill]?.box)
        let pillMenu = stage.menuOutline(at: stage.viewPoint(CGPoint(x: box.midX, y: box.midY)))
        stage.editor.selectedShapeIDs = []
        try stage.expand(["Pricing rules"])
        let mirrorMenu = stage.menuOutline(at: stage.viewPoint(CGPoint(x: box.midX, y: box.midY)))
        return .text((["A pill:"] + pillMenu + ["", "A mirror:"] + mirrorMenu).joined(separator: "\n"))
    },
    GalleryState("Mirror-8-panel", "Order #1042's mirror selected: the Reference tab first, then the note's own tabs, its Types tab shown",
                 size: CGSize(width: 340, height: 560)) { stage in
        try mirrorKinds(stage)
        try stage.expand(["Order #1042"])
        let mirror = try stage.pill(for: "Order #1042")
        return .image(try stage.panelPicture(of: mirror, tab: .of(TypesTab.self), size: CGSize(width: 340, height: 560)))
    },
]
