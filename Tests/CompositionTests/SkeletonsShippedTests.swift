import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Connections
import CoreGraphics
import Geometry
import LanguageModels
import Locking
import Mentions
import Schemas
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles

// Skeletons as shipped: below 35% every shipped kind draws its skeleton, which says nothing but
// what a shape is called (Titles' cover, on it), and no adornment is shown on it (a title's pill,
// a lock); at 35% all of it is drawn in full; the note being edited is drawn in full whatever the
// zoom; and a mention's pill is no face on a skeleton. The kinds' own tests hold what each
// skeleton looks like; here, the pieces together.

/// A subboard, a titled note that mentions it, another note with an arrow to it, a locked empty
/// note and a schema card: every word on the board said through `say`, but the titles (a cover
/// says its shape's), so two boards that say the same number of letters, in different letters,
/// differ only where text is drawn.
@MainActor
private struct SkeletonBoard {
    let subboard = ShapeID(), note = ShapeID(), other = ShapeID(), arrow = ShapeID(), locked = ShapeID(), card = ShapeID()
    /// Letters no other test's notes say, so the canvas has built nothing of this note's text.
    let token = String(UUID().uuidString.prefix(8))

    static let subboardFrame = CGRect(x: 100, y: 100, width: 240, height: 160)
    static let noteFrame = CGRect(x: 400, y: 100, width: 200, height: 200)
    static let otherFrame = CGRect(x: 700, y: 100, width: 200, height: 200)
    static let lockedFrame = CGRect(x: 100, y: 400, width: 160, height: 120)
    /// Between the notes, where the arrow runs.
    static let arrowRect = CGRect(x: 610, y: 180, width: 80, height: 40)

    /// `card`: the schema card's id, if not `self.card`. Readings of cards are kept by id, whatever
    /// the editor (`SchemaReadings`), so two boards that say different things each need a card of
    /// their own, or each would read as a card whose text changed (and draw bars by its id).
    func place(on editor: CanvasEditor, card cardID: ShapeID? = nil, _ say: (String) -> String = { $0 }) throws {
        var subboard = ShapeRecord(id: subboard, Subboard(frame: Self.subboardFrame))
        subboard[TitleProperty.self] = "Roadmap"
        var note = ShapeRecord(id: note, StickyNote(frame: Self.noteFrame, text: MentionText([
            .text(say("Ask \(token) ")), .mention(self.subboard, label: say("Roadmap")), .text(say(" about the launch")),
        ])))
        note[TitleProperty.self] = "Groceries"
        let other = ShapeRecord(id: other, StickyNote(frame: Self.otherFrame, text: MentionText(plain: say("See you there"))))
        let bound = { (id: ShapeID) in
            ArrowTerminal.bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        let arrow = ShapeRecord(id: arrow, Arrow(start: bound(self.note), end: bound(self.other)))
        var locked = ShapeRecord(id: locked, StickyNote(frame: Self.lockedFrame, text: MentionText(plain: "")))
        locked[LockedProperty.self] = true
        var card = SchemaCard(frame: CGRect(origin: CGPoint(x: 400, y: 400), size: SchemaCard.defaultSize))
        card.schema.text = #"{"title": "Pet", "type": "object", "properties": {"\#(say("name"))": {"type": "string"}, "\#(say("species"))": {"type": "string"}}, "required": ["\#(say("name"))"]}"#
        card.setPrompt(SchemaPromptText(plain: say("A pet and its name")))
        let schema = ShapeRecord(id: cardID ?? self.card, card)
        editor.transact { t in
            t.insert(subboard)
            t.insert(note)
            t.insert(other)
            t.insert(arrow)
            t.insert(locked)
            t.insert(schema)
        }
    }

    var ids: [ShapeID] { [subboard, note, other, arrow, locked, card] }

    /// Where a shape is drawn, in view points: the arrow, between the notes.
    func rect(of id: ShapeID, in editor: CanvasEditor) -> CGRect {
        editor.camera.toView(id == arrow ? Self.arrowRect : editor.document[id]?.box ?? .null)
    }
}

/// The same number of letters, each another: ROT13.
private func rot13(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.map { c -> Unicode.Scalar in
        switch c {
        case "a"..."z": Unicode.Scalar((c.value - 97 + 13) % 26 + 97)!
        case "A"..."Z": Unicode.Scalar((c.value - 65 + 13) % 26 + 65)!
        default: c
        }
    }))
}

/// Byte for byte.
@MainActor private func identical(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh && a.bytesPerRow == b.bytesPerRow
        && memcmp(a.bitmapData!, b.bitmapData!, a.bytesPerRow * a.pixelsHigh) == 0
}

/// Where two renders of one size differ, for a failure's message: how many pixels, within what
/// (pixels, from the top left).
@MainActor private func differences(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> String {
    var count = 0, within = CGRect.null
    var p = [Int](repeating: 0, count: 4), q = p
    for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
        for x in 0..<min(a.pixelsWide, b.pixelsWide) {
            a.getPixel(&p, atX: x, y: y)
            b.getPixel(&q, atX: x, y: y)
            guard p != q else { continue }
            count += 1
            within = within.union(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return "\(count) pixels differ, within \(within)"
}

@MainActor private func shippedHarness(_ pasteboard: NSPasteboard) -> EditorHarness {
    EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
}

/// The board at 30%: 1,066 × 666 world units in view.
private let viewSize = CGSize(width: 320, height: 200)

@MainActor let skeletonsShippedTests = Suite("Skeletons, as shipped", [
    test("at 30% every shape is its skeleton and says nothing but its title, which is on it, with no pill and no lock; at 35% it's all in full; the note being edited is in full at 30%") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let board = SkeletonBoard()
        let said = shippedHarness(pasteboard), other = shippedHarness(pasteboard)
        try board.place(on: said.editor)
        try board.place(on: other.editor, card: ShapeID(), rot13)
        let editor = said.editor
        let far = Camera(zoom: 0.3), near = Camera(zoom: 0.35)

        // At 30%, two boards that say different letters draw alike: no text anywhere but the titles'
        // covers, which say the same, and no pill and no lock.
        editor.camera = far
        other.editor.camera = far
        expect(editor.drawsSkeletons)
        expectEqual(board.ids.filter { !editor.drawsSkeleton(of: $0) }, [], "every shape a skeleton")
        #if DEBUG
        var built = MentionDrawingCounts.stringsBuilt
        #endif
        for scale: CGFloat in [1, 2] {
            let a = renderBitmap(editor, size: viewSize, scale: scale), b = renderBitmap(other.editor, size: viewSize, scale: scale)
            expect(identical(a, b), "at \(scale)×: \(differences(a, b))")
        }
        #if DEBUG
        expectEqual(MentionDrawingCounts.stringsBuilt, built, "no mention text built")
        #endif

        // The titles are on the shapes: the subboard's and the note's.
        expectEqual(editor.titleCover(of: board.subboard)?.text, "Roadmap")
        expectEqual(editor.titleCover(of: board.note)?.text, "Groceries")
        expectEqual(editor.adornmentFrames(of: board.note), [], "and no pill above it")
        let text = editor.camera.toView(try require(editor.titleCover(of: board.note)).rect).insetBy(dx: -1, dy: -1).integral
        let covered = renderBitmap(editor, size: viewSize)
        editor.transact { $0.update(board.note) { $0[TitleProperty.self] = nil } }
        expect(changedPixels(covered, renderBitmap(editor, size: viewSize), in: text) > 30, "the note's title, drawn on it")
        editor.transact { $0.update(board.note) { $0[TitleProperty.self] = "Groceries" } }

        // At 35%, all of it in full: each shape's words, and the pills'. The other board's titles
        // say other letters now.
        other.editor.transact { transaction in
            for id in [board.note, board.subboard] {
                transaction.update(id) { $0[TitleProperty.self] = $0[TitleProperty.self].map(rot13) }
            }
        }
        editor.camera = near
        other.editor.camera = near
        expect(!editor.drawsSkeletons)
        #if DEBUG
        built = MentionDrawingCounts.stringsBuilt
        #endif
        let fullA = renderBitmap(editor, size: viewSize), fullB = renderBitmap(other.editor, size: viewSize)
        #if DEBUG
        expect(MentionDrawingCounts.stringsBuilt > built, "the note's mention text built")
        #endif
        for id in [board.note, board.other, board.card] {
            expect(changedPixels(fullA, fullB, in: board.rect(of: id, in: editor)) > 20, "\(editor.document[id]?.kind.rawValue ?? "?") says its words")
        }
        for id in [board.note, board.subboard] {
            let pill = try require(editor.adornmentFrames(of: id).first { $0.adornment == .of(TitlePill.self) }).rect
            expect(changedPixels(fullA, fullB, in: editor.camera.toView(pill)) > 10, "\(editor.document[id]?.kind.rawValue ?? "?")'s pill says its title")
        }

        // At 30%, each shape is its skeleton, where in full it's drawn otherwise (an empty note only
        // by its corners and its shadow, so each is looked at with a few points around it).
        editor.camera = far
        let level = editor.skeletonZoom
        let skeletons = renderBitmap(editor, size: viewSize)
        editor.skeletonZoom = 0
        let full = renderBitmap(editor, size: viewSize)
        editor.skeletonZoom = level
        for id in board.ids {
            expect(changedPixels(skeletons, full, in: board.rect(of: id, in: editor).insetBy(dx: -3, dy: -3)) > 0,
                   "\(editor.document[id]?.kind.rawValue ?? "?") is its skeleton")
        }

        // The lock isn't shown on a skeleton: shut, or open (until it fades), the board draws alike;
        // at 35% the lock and the open lock differ.
        @MainActor func chip() throws -> CGRect {
            editor.camera.toView(try require(editor.adornmentFrames(of: board.locked).first { $0.adornment == .of(LockChip.self) }).rect)
        }
        /// Drawn unlocked, the lock open, then locked again.
        @MainActor func unlocked() -> NSBitmapImageRep {
            editor.unlock([board.locked])
            defer { editor.lock([board.locked]) }
            return renderBitmap(editor, size: viewSize)
        }
        expectEqual(editor.adornmentFrames(of: board.locked), [], "no chip on a skeleton")
        let open = unlocked()
        expect(identical(skeletons, open), "no lock, shut or open: \(differences(skeletons, open))")
        editor.camera = near
        let locked = renderBitmap(editor, size: viewSize)
        expect(changedPixels(locked, unlocked(), in: try chip()) > 0, "in full, the open lock isn't the lock")

        // The note being edited is drawn in full at 30%, the others still skeletons.
        editor.camera = far
        expect(editor.beginEditing(board.note))
        expect(!editor.drawsSkeleton(of: board.note))
        expect(editor.drawsSkeleton(of: board.other))
        let editing = renderBitmap(editor, size: viewSize)
        editor.skeletonZoom = 0
        let editingFull = renderBitmap(editor, size: viewSize)
        editor.skeletonZoom = level
        expectEqual(changedPixels(editing, editingFull, in: board.rect(of: board.note, in: editor).insetBy(dx: 2, dy: 2)), 0, "the edited note, in full")
        expect(changedPixels(editing, editingFull, in: board.rect(of: board.other, in: editor)) > 20, "the other, a skeleton")
    },
    test("in the app's canvas view at 30%, a click where a mention's pill is selects the note, which hovers, and a double-click edits it without following the mention; at 35% the pill is a face again") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let board = SkeletonBoard()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        try board.place(on: editor)
        editor.camera = Camera(zoom: 0.3)
        let pill = try require(editor.mentionPills(of: board.note).first, "the note's pill")
        expectEqual(pill.target, board.subboard)
        var time: TimeInterval = 1
        /// A click (or a double-click's second) at the pill's middle, `after` seconds after the last.
        @MainActor func click(clicks: Int = 1, after: TimeInterval = 1) {
            time += after
            let point = editor.camera.toView(CGPoint(x: pill.frame.midX, y: pill.frame.midY))
            canvas.mouseMoved(with: window.mouse(.mouseMoved, at: point, clicks: 0, time: time))
            canvas.mouseDown(with: window.mouse(.leftMouseDown, at: point, clicks: clicks, time: time + 0.1))
            canvas.mouseUp(with: window.mouse(.leftMouseUp, at: point, clicks: clicks, time: time + 0.15))
        }

        click()
        expectEqual(editor.selection, board.note)
        expectEqual(editor.hovered, board.note, "the note, not what its pill names")
        expectEqual(editor.editingShapeID, nil, "a click on a skeleton's pill doesn't edit from it")
        click(clicks: 2, after: 0.2)
        expectEqual(editor.editingShapeID, board.note, "a double-click edits the note")
        let start = try require(editor.editingStartPoint, "from where it's pressed, as any double-click")
        expect(start.distance(to: CGPoint(x: pill.frame.midX, y: pill.frame.midY)) < 0.01, "there: \(start)")
        expectEqual(editor.board, .root, "and doesn't go into the subboard")
        editor.endEditing()

        // At 35%, the pill is a face: the pointer on it hovers the subboard, and a click edits the
        // note from it.
        editor.selection = nil
        editor.camera = Camera(zoom: 0.35)
        let face = try require(editor.mentionPills(of: board.note).first)
        let point = editor.camera.toView(CGPoint(x: face.frame.midX, y: face.frame.midY))
        time += 1
        canvas.mouseMoved(with: window.mouse(.mouseMoved, at: point, clicks: 0, time: time))
        expectEqual(editor.hovered, board.subboard, "the pill hovers what it names")
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: point, clicks: 1, time: time + 0.1))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: point, clicks: 1, time: time + 0.15))
        expectEqual(editor.editingShapeID, board.note)
        expect(editor.editingStartPoint != nil, "edited from the pill")
        editor.endEditing()
    },
])
