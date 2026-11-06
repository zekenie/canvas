import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Draw
import TextEditing
import Foundation
import Geometry
import Publishing
import References
import Selection
import TestKit
import Titles

// Reference pills as they are today: the codebase board and a hand-made product board, drawn with `canvas draw`,
// and every state of a pill, the ladder of long places and the colors. Files `Pill-*`.

private let orderSchema = #""{\"type\": \"object\", \"properties\": {\"total\": {\"type\": \"number\"}}}""#

extension GalleryStage {
    /// Runs a `canvas draw` script on the editor.
    func run(_ script: String) throws {
        do { _ = try draw(script: script, dryRun: false, reveal: false, program: "gallery", in: editor) } catch {
            throw GalleryFailure("draw refused: \(error)\n\(script)")
        }
        settlePills()
    }

    /// Lets the services answer, as the app's do after a wait for quiet.
    func settlePills() {
        for _ in 0..<4 {
            spin(0.05)
            scheduler.advance(by: .milliseconds(300))
        }
    }

    /// The id of the shape titled `title`, on any board of the file (the first of them).
    func shape(_ title: String) throws -> ShapeID {
        let file = editor.file
        for document in [file.root] + file.children.values {
            if let record = document.shapes.first(where: { $0[TitleProperty.self] == title }) { return record.id }
        }
        throw GalleryFailure("no shape titled \(title)")
    }

    func board(of title: String) throws -> BoardID { BoardID(owner: try shape(title)) }

    func show(_ board: BoardID) throws {
        guard editor.showBoard(board) else { throw GalleryFailure("can't show \(board)") }
        settlePills()
    }

    /// The camera so the shape's top-left is `inset` from the stage's.
    func look(at title: String, zoom: CGFloat = 1, inset: CGPoint = CGPoint(x: 20, y: 20)) throws {
        let box = try require(editor.file.record(try shape(title))?.box)
        look(at: CGPoint(x: box.minX - inset.x / zoom, y: box.minY - inset.y / zoom), zoom: zoom)
        settlePills()
    }

    /// A pill placed with the Reference tool at a world point and typed into: `text`, then Return picks the highlighted row.
    @discardableResult
    func pickPill(_ text: String, at world: CGPoint) throws -> ShapeID {
        window.type("r")
        let point = viewPoint(world)
        press(at: point)
        release(at: point)
        let id = try require(editor.editingShapeID, "editing begins at once")
        window.type(text)
        window.settle()
        window.pressReturn()
        hover(at: CGPoint(x: size.width - 5, y: size.height - 5))
        settlePills()
        return id
    }

    /// A dynamic pill holding `words` and `query`, put at `origin`.
    @discardableResult
    func dynamicPill(_ words: String, query: String, all: Bool, at origin: CGPoint) -> ShapeID {
        var props = Reference(frame: CGRect(origin: origin, size: Reference.defaultSize))
        ReferenceEdits.find(&props, words: words, query: query)
        props.all = all
        let id = editor.add(props)
        settlePills()
        return id
    }
}

/// The codebase: the layers' frames, the modules as subboard cards, the five cards of "Things you do" with a pill each
/// for the modules they use, drawn by their edges.
@MainActor private func codebase(_ stage: GalleryStage) throws {
    try stage.run("""
    frame "Core layer" size: 1500x330
    frame "Platform layer" below "Core layer" size: 1500x1700
    frame "Product layer" below "Platform layer" size: 1500x260
    frame "App layer" below "Product layer" size: 1500x260
    """)
    try stage.run("""
    subboard "Canvas" in "Core layer" size: 170x80
    subboard "Geometry" in "Core layer" right of "Canvas" size: 170x80
    subboard "FuzzyMatching" in "Core layer" right of "Geometry" size: 170x80
    subboard "TextEditing" in "Core layer" right of "FuzzyMatching" size: 170x80
    frame "Things you do" in "Platform layer" size: 1380x520
    frame "Horizontals: in the window" in "Platform layer" below "Things you do" size: 1380x240
    frame "Horizontals: shape traits" in "Platform layer" below "Horizontals: in the window" size: 1380x220
    frame "Engines" in "Platform layer" below "Horizontals: shape traits" size: 1380x220
    """)
    try stage.run("""
    subboard "Selection" in "Horizontals: in the window" size: 170x80
    subboard "ContextMenus" in "Horizontals: in the window" right of "Selection" size: 170x80
    subboard "Keyboard" in "Horizontals: in the window" right of "ContextMenus" size: 170x80
    subboard "TableOfContents" in "Horizontals: in the window" right of "Keyboard" size: 170x80
    subboard "SlashCommands" in "Horizontals: in the window" right of "TableOfContents" size: 170x80
    subboard "Titles" in "Horizontals: shape traits" size: 170x80
    subboard "Topology" in "Horizontals: shape traits" right of "Titles" size: 170x80
    subboard "Boards" in "Horizontals: shape traits" right of "Topology" size: 170x80
    subboard "Draw" in "Engines" size: 170x80
    subboard "Placing" in "Engines" right of "Draw" size: 170x80
    """)
    try stage.run("""
    subboard "Clipboard" in "Things you do" size: 150x70
    subboard "JumpTo" in "Things you do" right of "Clipboard" (gap: 270) size: 150x70
    subboard "Moving" in "Things you do" right of "JumpTo" (gap: 270) size: 150x70
    subboard "Reordering" in "Things you do" below "Clipboard" (gap: 190) size: 150x70
    subboard "Snapping" in "Things you do" right of "Reordering" (gap: 270) size: 150x70
    """)
    try stage.run("""
    edge "Clipboard" -> "Canvas" via: reference
    edge "Clipboard" -> "Geometry" via: reference
    edge "Clipboard" -> "TextEditing" via: reference
    edge "Clipboard" -> "Topology" via: reference
    edge "JumpTo" -> "Canvas" via: reference
    edge "JumpTo" -> "FuzzyMatching" via: reference
    edge "JumpTo" -> "Titles" via: reference
    edge "JumpTo" -> "Boards" via: reference
    edge "Moving" -> "Canvas" via: reference
    edge "Moving" -> "Draw" via: reference
    edge "Moving" -> "Selection" via: reference
    edge "Moving" -> "Topology" via: reference
    edge "Reordering" -> "Selection" via: reference
    edge "Reordering" -> "Keyboard" via: reference
    edge "Reordering" -> "ContextMenus" via: reference
    edge "Reordering" -> "SlashCommands" via: reference
    edge "Snapping" -> "Geometry" via: reference
    edge "Snapping" -> "Selection" via: reference
    edge "Snapping" -> "TableOfContents" via: reference
    """)
    stage.editor.selection = nil
}

/// Shop: the root board, Policies' board and Checkout's, with the pills on Checkout's drawn by edges; Checkout is shown.
@MainActor private func shop(_ stage: GalleryStage) throws {
    try stage.run("""
    frame "Identity" size: 640x280
    frame "Vendors" right of "Identity" size: 360x300
    """)
    try stage.run("""
    sticky-note "Auth" in "Identity" color: blue text: "Tokens and sessions" size: 180x100
    sticky-note "Retry" in "Identity" right of "Auth" text: "Back off, then try again" size: 180x100
    subboard "Stripe" in "Vendors" size: 200x100
    sticky-note "Order" below "Identity" color: purple schema: \(orderSchema) text: "An order has a total." size: 200x120
    sticky-note "Order #1042" right of "Order" is: "Order" text: "Two chairs" size: 200x120
    subboard "Policies" right of "Vendors" size: 200x100
    subboard "Checkout" below "Policies" size: 200x100
    """)
    var orders = ""
    for n in 0..<12 { orders += "sticky-note \"Order #\(2001 + n)\" is: \"Order\" text: \"Open\" size: 120x80 right of \(n == 0 ? "\"Order #1042\"" : "\"Order #\(2000 + n)\"")\n" }
    try stage.run(orders)
    try stage.run(#"frame "Refunds" in "Policies" color: green size: 640x260"#)
    try stage.run("""
    sticky-note "Refund window" in "Refunds" text: "Thirty days" size: 180x100
    sticky-note "Retry" in "Refunds" right of "Refund window" text: "Retry the refund" size: 180x100
    """)
    try stage.run("""
    sticky-note "Cart" in "Checkout" size: 160x100
    sticky-note "Pay" in "Checkout" right of "Cart" (gap: 250) size: 160x100
    sticky-note "Confirm" in "Checkout" right of "Pay" (gap: 250) size: 160x100
    frame "Rules" in "Checkout" below "Confirm" (gap: 260) size: 340x220
    """)
    try stage.run("""
    sticky-note "Pricing" in "Rules" color: orange text: "Per seat" size: 200x120
    sticky-note "Old checkout" in "Checkout" below "Cart" (gap: 500) size: 160x100
    edge "Cart" -> "Pay"
    edge "Pay" -> "Confirm"
    """)
    try stage.show(try stage.board(of: "Checkout"))
    try stage.run("""
    edge "Cart" -> "Auth" via: reference from: bottom
    edge "Cart" -> "Stripe" via: reference from: bottom
    edge "Cart" -> "Order #1042" via: reference from: bottom
    edge "Cart" -> "Old checkout" via: reference from: bottom
    edge "Pay" -> "Refunds" via: reference from: bottom channel: none
    edge "Pay" -> "Identity" > "Retry" via: reference from: bottom
    edge "Pay" -> "Refunds" > "Retry" via: reference from: bottom
    edge "Confirm" -> "Pricing" via: reference from: bottom
    """)
    let old = try stage.shape("Old checkout")
    stage.editor.transact("Delete") { $0.delete([old]) }
    stage.settlePills()
}

@MainActor let referencePillStates: [GalleryState] = [
    GalleryState("Pill-1-codebase", "the codebase board: Things you do at 100%, pills drawn by edges", size: CGSize(width: 1200, height: 760)) { stage in
        try codebase(stage)
        try stage.look(at: "Things you do")
        return .image(stage.picture())
    },
    GalleryState("Pill-2-checkout", "Shop's Checkout board: pills drawn by edges, one picked, a dynamic one, a deleted one", size: CGSize(width: 1200, height: 760)) { stage in
        try shop(stage)
        let box = try require(stage.editor.file.record(try stage.shape("Cart"))?.box)
        stage.look(at: CGPoint(x: box.minX - 40, y: box.minY - 90))
        stage.settlePills()
        try stage.pickPill("Refund window", at: CGPoint(x: box.minX + 40, y: box.minY - 40))
        stage.dynamicPill("open orders", query: #"sticky-note:is-a("Order")"#, all: true, at: CGPoint(x: box.minX + 600, y: box.minY - 40))
        stage.editor.selection = nil
        stage.settlePills()
        return .image(stage.picture())
    },

    GalleryState("Pill-3-states", "every kind a pill stands for, and every state, on a board of its own", size: CGSize(width: 1200, height: 760)) { stage in
        try stage.run("""
        frame "Team" size: 800x420
        frame "Green zone" right of "Team" color: green size: 300x300
        frame "Open zone" below "Team" size: 300x200
        subboard "Holder" below "Green zone" size: 200x100
        """)
        try stage.run("""
        sticky-note "Plan" in "Team" text: "Ship in June" size: 180x100
        sticky-note "Spec" in "Team" right of "Plan" color: blue text: "What we build" size: 180x100
        sticky-note "Draft" in "Team" below "Plan" text: "Not final" size: 180x100
        sticky-note "Gone" in "Team" right of "Draft" text: "Soon deleted" size: 180x100
        sticky-note "Order" below "Open zone" color: purple schema: \(orderSchema) text: "An order has a total." size: 200x120
        sticky-note "Order #7" right of "Order" is: "Order" text: "Two chairs" size: 200x120
        subboard "Billing" right of "Order #7" size: 200x100
        """)
        try stage.show(try stage.board(of: "Holder"))
        stage.look(at: .zero)
        let names = ["Plan", "Spec", "Order #7", "Order", "Billing", "Green zone", "Open zone", "Draft", "Gone"]
        for (n, name) in names.enumerated() {
            try stage.pickPill(name, at: CGPoint(x: 120 + CGFloat(n % 3) * 380, y: 60 + CGFloat(n / 3) * 80))
        }
        let draft = try stage.shape("Draft"), gone = try stage.shape("Gone")
        stage.editor.transact("Make Private") { $0.update(inFile: draft) { $0[PrivateProperty.self] = true } }
        stage.editor.transact("Delete") { $0.delete(inFile: [gone]) }
        stage.editor.add(Reference(frame: CGRect(x: 60, y: 320, width: 120, height: 40)))
        stage.dynamicPill("open orders", query: #"sticky-note:is-a("Order")"#, all: true, at: CGPoint(x: 440, y: 320))
        stage.dynamicPill("first order", query: #"sticky-note:is-a("Order")"#, all: false, at: CGPoint(x: 820, y: 320))
        stage.dynamicPill("nothing like this", query: #"sticky-note[text="zzzz"]"#, all: true, at: CGPoint(x: 60, y: 400))
        stage.editor.selection = nil
        stage.settlePills()
        return .image(stage.picture())
    },
    GalleryState("Pill-4-zoomed-out", "the codebase board at 30%", size: CGSize(width: 1200, height: 760)) { stage in
        try codebase(stage)
        let box = try require(stage.editor.file.record(try stage.shape("Things you do"))?.box)
        stage.look(at: CGPoint(x: box.minX - 100, y: box.minY - 100), zoom: 0.3)
        stage.settlePills()
        return .image(stage.picture())
    },
    GalleryState("Pill-5-panel", "a pill selected: the inspector's Reference tab", size: CGSize(width: 340, height: 420)) { stage in
        try codebase(stage)
        let pill = try require(stage.editor.document.shapes.first { ($0.props as? Reference)?.target?.label == "TextEditing" })
        return .image(try stage.panelPicture(of: pill.id, tab: nil, size: CGSize(width: 340, height: 420)))
    },
    GalleryState("Pill-6-picker", "a new pill typed `ret`: the list with the two Retry notes", size: CGSize(width: 1200, height: 760)) { stage in
        try shop(stage)
        let box = try require(stage.editor.file.record(try stage.shape("Cart"))?.box)
        stage.look(at: CGPoint(x: box.minX - 40, y: box.minY - 90))
        stage.window.type("r")
        let point = stage.viewPoint(CGPoint(x: box.minX + 100, y: box.minY - 40))
        stage.press(at: point)
        stage.release(at: point)
        stage.window.type("ret")
        stage.window.settle()
        stage.spin(0.2)
        let view = try require(stage.window.firstResponder as? EditingTextView, "the pill's field has the keyboard")
        let caret = view.firstRect(forCharacterRange: NSRange(location: view.selectedRange().location, length: 0), actualRange: nil)
        return .image(try stage.pictureWithList(stage.listRows(in: view.caretListWindow), below: stage.window.convertFromScreen(caret)))
    },
    GalleryState("Pill-7-dense", "one card, twelve pills beside it, drawn by edges", size: CGSize(width: 1200, height: 760)) { stage in
        try stage.run("""
        frame "Library" size: 2600x200
        frame "Work" below "Library" size: 1500x1100
        """)
        let names = ["Auth", "Billing", "Catalog", "Search", "Mail", "Queue", "Cache", "Logging", "Metrics", "Storage", "Payments", "Reports"]
        var notes = ""
        for (n, name) in names.enumerated() { notes += "sticky-note \"\(name)\" in \"Library\" size: 120x70 \(n == 0 ? "" : "right of \"\(names[n - 1])\"")\n" }
        try stage.run(notes)
        try stage.run(#"subboard "Checkout" in "Work" inside "Work" left size: 170x80"#)
        try stage.run(names.map { "edge \"Checkout\" -> \"\($0)\" via: reference" }.joined(separator: "\n"))
        let card = try require(stage.editor.file.record(try stage.shape("Checkout"))?.box)
        stage.look(at: CGPoint(x: card.minX - 40, y: card.midY - 380))
        stage.settlePills()
        return .image(stage.picture())
    },
    GalleryState("Pill-8-long-places", "one note moved one to seven levels deep across Shop, Policies and Disputes: the place folds as the levels grow", size: CGSize(width: 1200, height: 760)) { stage in
        try longPlaces(stage)
        let box = try require(stage.editor.file.record(try stage.shape("Intake"))?.box)
        stage.look(at: CGPoint(x: box.minX - 40, y: box.minY - 260))
        stage.editor.selection = nil
        stage.settlePills()
        return .image(stage.picture())
    },
    GalleryState("Pill-9-colors", "a pill for each built-in color on a note, a subboard and a frame, and a plain frame's gray", size: CGSize(width: 1200, height: 760)) { stage in
        try colors(stage)
        let box = try require(stage.editor.file.record(try stage.shape("By note"))?.box)
        stage.look(at: CGPoint(x: box.minX - 30, y: box.minY - 300), zoom: 0.8)
        stage.editor.selection = nil
        stage.settlePills()
        return .image(stage.picture())
    },
]

/// Shop is the file; Policies and Disputes are subboards, Refunds, Escalations, EU and Q3 review frames: seven notes of one name and a number, each
/// one level deeper than the last (`Shop`, `Policies`, `Policies > Refunds`, ... to `... > Disputes > Q3 review`), and a pill for
/// each, drawn by edges on the board of a card, "Review".
@MainActor private func longPlaces(_ stage: GalleryStage) throws {
    stage.editor.nameRoot("Shop")
    try stage.run("""
    subboard "Policies" size: 200x100
    subboard "Review" right of "Policies" size: 200x100
    sticky-note "Chargeback reply 1" size: 160x100 below "Policies"
    """)
    // One run a level: a shape goes in a container the file already has.
    let levels = [
        #"frame "Refunds" in "Policies" size: 1500x1200"#,
        #"sticky-note "Chargeback reply 2" in "Policies" below "Refunds" size: 160x100"#,
        #"frame "Escalations" in "Refunds" size: 1300x900"#,
        #"sticky-note "Chargeback reply 3" in "Refunds" below "Escalations" size: 160x100"#,
        #"frame "EU" in "Escalations" size: 1100x450"#,
        #"sticky-note "Chargeback reply 4" in "Escalations" below "EU" size: 160x100"#,
        #"subboard "Disputes" in "EU" size: 200x100"#,
        #"sticky-note "Chargeback reply 5" in "EU" below "Disputes" size: 160x100"#,
        #"frame "Q3 review" in "Disputes" size: 600x300"#,
        #"sticky-note "Chargeback reply 6" in "Disputes" below "Q3 review" size: 160x100"#,
        #"sticky-note "Chargeback reply 7" in "Q3 review" size: 160x100"#,
    ]
    for level in levels { try stage.run(level) }
    try stage.show(try stage.board(of: "Review"))
    try stage.run(#"sticky-note "Intake" size: 160x100"#)
    // A script can't reach into a board it isn't on by a path, so each note is called by its own title.
    try stage.run((1...7).map { "edge \"Intake\" -> \"Chargeback reply \($0)\" via: reference" }.joined(separator: "\n"))
}

private let builtInColors = ["gray", "red", "orange", "yellow", "green", "teal", "blue", "indigo", "purple", "pink"]

/// Originals of every built-in color (notes, subboards, frames) in a frame each, and three cards on a board of their own with a
/// pill for each original.
@MainActor private func colors(_ stage: GalleryStage) throws {
    try stage.run("""
    frame "Notes" size: 2300x220
    frame "Subboards" below "Notes" size: 2300x220
    frame "Frames" below "Subboards" size: 2300x220
    subboard "Swatches" below "Frames" size: 200x100
    """)
    for (kind, container) in [("sticky-note", "Notes"), ("subboard", "Subboards"), ("frame", "Frames")] {
        var script = ""
        for (n, color) in builtInColors.enumerated() {
            let title = "\(container.dropLast()) \(color)"
            script += "\(kind) \"\(title)\" in \"\(container)\" color: \(color) size: 120x70\(n == 0 ? "" : " right of \"\(container.dropLast()) \(builtInColors[n - 1])\"")\n"
        }
        try stage.run(script)
    }
    try stage.show(try stage.board(of: "Swatches"))
    try stage.run("""
    subboard "By note" size: 200x100
    subboard "By subboard" right of "By note" (gap: 270) size: 200x100
    subboard "By frame" right of "By subboard" (gap: 270) size: 200x100
    """)
    for (card, container) in [("By note", "Notes"), ("By subboard", "Subboards"), ("By frame", "Frames")] {
        try stage.run(builtInColors.map { "edge \"\(card)\" -> \"\(container.dropLast()) \($0)\" via: reference" }.joined(separator: "\n"))
    }
}
