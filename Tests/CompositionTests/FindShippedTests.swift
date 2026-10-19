import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Find
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Types

// Find in the shipped app: Edit › Find's items, the inspector it shows, and what it finds in the
// shipped kinds (a note's text, a type note's too, an arrow's label, a title), on every
// board under the one shown.

extension NestedWindow {
    var find: FindState { editor.find! }
    /// Find's field, while its panel shows.
    var findField: NSTextField? {
        window.contentView?.descendants(NSTextField.self).first { $0.isEditable && $0.placeholderString == "Find" }
    }
    var findFieldHasKeyboard: Bool {
        guard let text = window.firstResponder as? NSTextView, let field = findField else { return false }
        return text.delegate === field
    }
    /// The app's Edit › Find items, sent to this window's controller.
    func findItems() throws -> (menus: BoardMenus.Menus, find: NSMenuItem, next: NSMenuItem, previous: NSMenuItem) {
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: editor.registry)
        let submenu = try require(menus.main.item(withTitle: "Edit")?.submenu?.item(withTitle: "Find")?.submenu)
        for item in submenu.items { item.target = controller }
        return (menus, try require(submenu.item(withTitle: "Find…")), try require(submenu.item(withTitle: "Find Next")),
                try require(submenu.item(withTitle: "Find Previous")))
    }
}

/// Runs the scheduler's turns and the run loop until Find has answered.
@MainActor private func settled(_ find: FindState, _ h: EditorHarness) throws {
    while find.isIndexing { h.wait(0) }
    _ = try awaitResult { await find.settled() }
}

/// `renderBitmap`, in either appearance.
@MainActor private func renderBitmap(_ editor: CanvasEditor, size: CGSize, dark: Bool) -> NSBitmapImageRep {
    var rep: NSBitmapImageRep!
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let bounds = CGRect(origin: .zero, size: size)
        editor.draw(in: cg, bounds: bounds, dirtyRect: bounds)
        NSGraphicsContext.restoreGraphicsState()
        rep = bitmap
    }
    return rep
}

@MainActor let findShippedTests = Suite("Find, shipped", [
    test("Edit › Find's items run Find's commands from the canvas, a panel's field and a note being edited; Find Next and Previous while there's something to step to") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (menus, findItem, next, previous) = try w.findItems()
        expect(w.controller.validateMenuItem(findItem))
        expect(!w.controller.validateMenuItem(next) && !w.controller.validateMenuItem(previous), "nothing typed yet")
        // From the canvas, its own shortcut answers first.
        w.window.makeFirstResponder(w.canvas)
        expect(w.canvas.performKeyEquivalent(with: w.window.keyEvent("f", code: 3, modifiers: .command)))
        expect(w.find.isActive)
        w.window.spin { w.findFieldHasKeyboard }
        w.window.type("first")
        w.window.spin { w.find.isSettled && w.find.total == 3 }
        expect(w.controller.validateMenuItem(next) && w.controller.validateMenuItem(previous))
        // Find's field has the keyboard: the keys are the menu bar's.
        expectEqual(w.find.currentNumber, 1)
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("g", code: 5, modifiers: .command)))
        expectEqual(w.find.currentNumber, 2)
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("G", ignoringModifiers: "g", code: 5, modifiers: [.command, .shift])))
        expectEqual(w.find.currentNumber, 1)
        expect(w.findFieldHasKeyboard, "stepping leaves the keyboard in the field")
        // A note being edited: ⌘F ends editing, and what's selected in it is what's typed.
        w.find.close()
        w.window.spin { w.findField == nil }
        let (note, _) = w.nest.notes(on: 1)
        expectEqual(w.editor.board, .root)
        expect(w.editor.beginEditing(note))
        w.window.spin { (w.window.firstResponder as? NSTextView)?.string.hasPrefix("Root") == true }
        let text = try require(w.window.firstResponder as? NSTextView)
        text.setSelectedRange(NSRange(location: 0, length: 4))
        expect(w.controller.validateMenuItem(findItem), "enabled in a note's text")
        expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("f", code: 3, modifiers: .command)))
        expectEqual(w.editor.editingShapeID, nil, "editing ended")
        expectEqual(w.find.query, "Root")
        w.window.spin { w.findFieldHasKeyboard }
        w.window.spin { w.find.isSettled && w.find.total == 2 }
    },
    test("a selection across a mention's pill seeds Find with the pill's name, not the character it is in the text") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (menus, _, _, _) = try w.findItems()
        let target = w.editor.add(StickyNote(frame: CGRect(x: 700, y: 80, width: 200, height: 200), text: "Walrus"))
        let note = w.editor.add(StickyNote(frame: CGRect(x: 80, y: 380, width: 240, height: 200),
                                           text: MentionText([.text("Feed "), .mention(target, label: "Old"), .text(" now")])))
        for (selection, query) in [(NSRange(location: 0, length: 10), "Feed Walrus now"), (NSRange(location: 5, length: 1), "Walrus")] {
            expect(w.editor.beginEditing(note))
            w.window.spin { w.window.firstResponder is MentionTextView<AnyMentionable> }
            let text = try require(w.window.firstResponder as? NSTextView)
            expectEqual(text.string.utf16.count, 10, "a pill is one character")
            text.setSelectedRange(selection)
            expect(menus.main.performKeyEquivalent(with: w.window.keyEvent("f", code: 3, modifiers: .command)))
            expectEqual(w.find.query, query, "seeded with what the pill reads as")
            w.find.close()
            w.window.spin { w.findField == nil }
        }
    },
    test("⌘F shows a hidden inspector, and closing Find hides it again; the keyboard goes back to the canvas") {
        let w = try NestedWindow()
        defer { w.board.close() }
        w.board.viewState.showsDetails = false
        w.window.settle()
        w.window.makeFirstResponder(w.canvas)
        expect(w.canvas.performKeyEquivalent(with: w.window.keyEvent("f", code: 3, modifiers: .command)))
        w.window.spin { w.board.viewState.showsDetails }
        w.window.spin { w.findFieldHasKeyboard }
        w.window.pressEscape()
        w.window.spin { !w.find.isActive }
        w.window.spin { !w.board.viewState.showsDetails }
        w.window.spin { w.window.firstResponder === w.canvas }
        // Shown by the person, it stays as Find closes.
        w.board.viewState.showsDetails = true
        w.window.settle()
        expect(w.canvas.performKeyEquivalent(with: w.window.keyEvent("f", code: 3, modifiers: .command)))
        w.window.spin { w.findFieldHasKeyboard }
        w.window.pressEscape()
        w.window.spin { !w.find.isActive }
        w.window.settle()
        expect(w.board.viewState.showsDetails)
    },
    test("hiding the inspector while Find is open closes Find: no highlights and no ⌘G stepping with no panel to close it by") {
        let w = try NestedWindow()
        defer { w.board.close() }
        w.window.makeFirstResponder(w.canvas)
        expect(w.canvas.performKeyEquivalent(with: w.window.keyEvent("f", code: 3, modifiers: .command)))
        w.window.spin { w.findFieldHasKeyboard }
        w.window.type("first")
        w.window.spin { w.find.isSettled && w.find.total == 3 }
        expect(w.board.viewState.showsDetails)
        w.board.viewState.showsDetails = false
        w.window.spin { !w.find.isActive }
        w.window.spin { w.window.firstResponder === w.canvas }
        expectEqual(w.find.query, "first", "what's typed is kept")
        w.board.viewState.showsDetails = true
        w.window.settle()
        expect(!w.find.isActive, "showing it again doesn't reopen Find")
    },
    test("a note's text, a type note's, an arrow's label and a title are found, and each highlighted where it's drawn") {
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, model: ScriptedLanguageModel()) }
        h.editor.viewportDidResize(to: CGSize(width: 1200, height: 800))
        let note = h.add(StickyNote(frame: CGRect(x: 40, y: 80, width: 200, height: 200), text: "Feed the walrus"))
        let card = h.editor.addTypeNote(TypeSchemaProperty.starter, text: "Walrus facts", frame: CGRect(x: 300, y: 80, width: 200, height: 200))
        let arrow = h.add(Arrow(start: .free(CGPoint(x: 600, y: 200)), end: .free(CGPoint(x: 1000, y: 200)), text: "to the walrus"))
        let board = h.editor.add(Subboard(frame: CGRect(x: 40, y: 420, width: 240, height: 160)), title: "Walrus pen")
        let find = try require(h.editor.find)
        find.open()
        find.query = "walrus"
        try settled(find, h)
        expectEqual(Set(find.results.map(\.id)), [note, card, arrow, board])
        let lit = renderBitmap(h.editor, size: CGSize(width: 1200, height: 800))
        var rects: [ShapeID: CGRect] = [:]
        for result in find.results {
            rects[result.id] = try require(find.rects(of: result.first, in: result.id).first, "\(result.id)")
        }
        find.close()
        let plain = renderBitmap(h.editor, size: CGSize(width: 1200, height: 800))
        for (id, rect) in rects {
            // A ring is outside its pill; a mark or a wash over its text.
            let spot = id == board ? CGPoint(x: rect.midX, y: rect.minY - 2) : CGPoint(x: rect.minX + 1, y: rect.minY + 1)
            expect(pixel(lit, at: spot) != pixel(plain, at: spot), "\(id == note ? "note" : id == card ? "type note" : id == arrow ? "arrow" : "title"): highlighted")
        }
    },
    test("Find's list is no table: the inspector's tables stay the panel's own") {
        let w = try InspectorWindow(file: CanvasFile(root: CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 40, y: 80, width: 200, height: 200), text: "walrus"))),
            AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 300, y: 80, width: 200, height: 200), text: "walrus too"))),
        ])))
        let find = try require(w.editor.find)
        find.open()
        find.query = "walrus"
        w.window.spin { find.isSettled && find.total == 2 }
        w.window.settle()
        expectEqual(w.tables.count, 0)
    },
    test("a hit reads on a note's yellow, a type note's too, light and dark: an orange") {
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, model: ScriptedLanguageModel()) }
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 400))
        let note = h.add(StickyNote(frame: CGRect(x: 40, y: 80, width: 200, height: 200), text: "walrus"))
        let card = h.editor.addTypeNote(TypeSchemaProperty.starter, text: "walrus", frame: CGRect(x: 300, y: 80, width: 200, height: 200))
        let find = try require(h.editor.find)
        find.open()
        find.query = "walrus"
        try settled(find, h)
        let size = CGSize(width: 800, height: 400)
        for dark in [false, true] {
            let lit = renderBitmap(h.editor, size: size, dark: dark)
            find.close()
            let plain = renderBitmap(h.editor, size: size, dark: dark)
            find.open()
            try settled(find, h)
            for id in [note, card] {
                let result = try require(find.results.first { $0.id == id })
                let current = find.currentHit?.shape == id
                let rect = try require(find.rects(of: result.first, in: id).first)
                let spot = CGPoint(x: rect.minX + 1, y: rect.minY + 1)
                let (on, off) = (pixel(lit, at: spot), pixel(plain, at: spot))
                let name = "\(id == note ? "note" : "type note") \(dark ? "dark" : "light")\(current ? ", current" : ""): \(off) → \(on)"
                expect(zip(on, off).prefix(3).map { abs($0 - $1) }.reduce(0, +) >= 90, "\(name): stands out")
                expect(on[0] > on[1] && on[1] > on[2] && on[0] - on[2] >= 120, "\(name): orange")
            }
        }
    },
    test("a note that is a Person is found by a value, marked on its row, light and dark; and by a date's shown form once its type's field turns from Text to Date") {
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, model: ScriptedLanguageModel()) }
        let size = CGSize(width: 800, height: 400)
        h.editor.viewportDidResize(to: size)
        let person = FieldFixtures.person
        h.editor.addTypeNote(person.schema, title: person.title, frame: CGRect(x: 500, y: 80, width: 200, height: 200), id: person.id)
        var ann = ShapeRecord(StickyNote(frame: CGRect(x: 40, y: 80, width: 200, height: 200), text: ""))
        ann[IsAProperty.self] = [TypeLink(person.id)]
        ann[FieldValuesProperty.self] = FieldValues(["name": "Ann Lee"])
        let id = ann.id
        h.editor.transact { $0.insert(AnyShapeRecord(ann)) }
        let find = try require(h.editor.find)
        find.open()
        find.query = "lee"
        try settled(find, h)
        expectEqual(find.results.map(\.id), [id])
        let row = try require(h.editor.rowBook?.rows(of: id).first { $0.name == "name" })
        let rect = try require(find.rects(of: try require(find.results.first).first, in: id).first)
        expect(row.rect.insetBy(dx: -2.5, dy: -1).contains(rect), "on the name's row: \(rect) in \(row.rect)")
        for dark in [false, true] {
            let lit = renderBitmap(h.editor, size: size, dark: dark)
            find.close()
            let plain = renderBitmap(h.editor, size: size, dark: dark)
            find.open()
            try settled(find, h)
            let spot = CGPoint(x: row.valueRect.minX + 1, y: row.rect.minY + 3)
            let (on, off) = (pixel(lit, at: spot), pixel(plain, at: spot))
            let name = "\(dark ? "dark" : "light"): \(off) → \(on)"
            expect(zip(on, off).prefix(3).map { abs($0 - $1) }.reduce(0, +) >= 90, "\(name): stands out")
            expect(on[0] > on[1] && on[1] > on[2] && on[0] - on[2] >= 120, "\(name): orange")
        }
        find.close()
        // A type whose field is Text, and then Date: the instance did not change, and is read as it shows now.
        let event = ShapeID()
        let text = #"{"type": "object", "properties": {"when": {"type": "string"}}}"#
        h.editor.addTypeNote(text, title: "Event", frame: CGRect(x: 500, y: 300, width: 200, height: 60), id: event)
        var meeting = ShapeRecord(StickyNote(frame: CGRect(x: 300, y: 80, width: 200, height: 200), text: ""))
        meeting[IsAProperty.self] = [TypeLink(event)]
        meeting[FieldValuesProperty.self] = FieldValues(["when": "2026-03-03"])
        let held = meeting.id
        h.editor.transact { $0.insert(AnyShapeRecord(meeting)) }
        find.open()
        find.query = "2026"
        try settled(find, h)
        expectEqual(find.results.map(\.id), [held])
        h.editor.transact("Date") { $0.update(event) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"when": {"type": "string", "format": "date"}}}"#) } }
        let shown = FieldText.shown(.string("2026-03-03"), as: .date)
        expectEqual(find.texts(of: held), [shown])
        find.query = shown
        try settled(find, h)
        expectEqual(find.results.map(\.id), [held], "found by the date as it shows")
    },
    test("a subboard's contents are found from the root, after the root's, each board's in turn") {
        let nest = NestedFile()
        let h = try EditorHarness { CanvasEditor(registry: try ShippedPlugins.registry(model: ScriptedLanguageModel()), file: nest.file, scheduler: $0) }
        let find = try require(h.editor.find)
        find.open()
        find.query = "second"
        try settled(find, h)
        expectEqual(find.results.map(\.id), [nest.notes(on: 1).1, nest.notes(on: 2).1, nest.notes(on: 3).1])
        expectEqual(find.results.map(\.board), [.root, nest.sBoard, nest.tBoard])
        // Each board's rows are headed as the path names the board: Boards', for Find's list.
        h.editor.nameRoot("Roadmap")
        expectEqual(find.results.map { find.heading(of: $0.board) },
                    [FindHeading("Roadmap"), FindHeading("Plans", systemImage: "rectangle.stack"), FindHeading("Untitled Subboard", systemImage: "rectangle.stack")])
        find.step(forward: true)
        find.step(forward: true)
        expectEqual(h.editor.board, nest.tBoard, "two boards down")
        find.close()
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "one step back to where Find began")
    },
])
