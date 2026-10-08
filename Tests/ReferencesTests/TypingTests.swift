import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import References
import TestKit
import TextEditing
import Topology

// Typing into a pill, in the field over it with the list under it: placing, typing, picking (Return,
// Tab, a click), the words row and the hand-off, ⌥Return, Escape twice, leaving, a new empty pill, a
// pill edited again, and the steps each is. The keys are sent to the window, as the keyboard sends them.

@MainActor private func setUp() throws -> (h: EditorHarness, plans: ShapeID, pricing: ShapeID) {
    let h = try referenceHarness()
    let plans = h.addBox("Plan B", at: CGRect(x: 100, y: 100, width: 150, height: 100))
    let pricing = h.addBox("Pricing and plans", at: CGRect(x: 100, y: 400, width: 150, height: 100))
    return (h, plans, pricing)
}

@MainActor let typingTests = Suite("Typing into a pill", [
    test("placing opens the list on the public shapes, with the keyboard in the field; nothing is written until something is typed") {
        let (h, _, _) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        expect(field.textView.holdsKeys, "the list is open at the field")
        expectEqual(Set(field.titles), ["Plan B", "Pricing and plans"])
        expectEqual(field.rows.compactMap(\.item).count, 2, "no words row, no headers")
        expectEqual(field.window.firstResponder === field.textView, true)
        expectEqual(h.reference(field.id)?.mode, .empty)
        expectEqual(h.editor.undoHistory.undoName, "Add Reference")
    },

    test("typing ranks the list over the public shapes as it goes, the words row last, and writes the words and the width in the step") {
        let (h, _, _) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("pla")
        expectEqual(h.reference(field.id)?.words, "pla")
        expectEqual(field.titles.first, "Plan B")
        expectEqual(field.titles.last, "pla", "the words row is last")
        expect(field.rows.compactMap(\.item).last?.separated == true)
        expectEqual(field.list?.list.highlighted, 0, "the first shape")
        field.type("n B")
        expectEqual(field.titles, ["Plan B", "plan B"])
        field.type("ig")
        expectEqual(field.titles, ["plan Big"], "no shape left: the words row alone")
        expectEqual(field.list?.list.highlighted, 0, "highlighted")
        expectEqual(h.editor.undoHistory.undoName, "Add Reference")
    },

    test("Return picks the highlighted shape: it stands for it, its words and query let go of, the width fit to its name, editing ends; one step, \"Add Reference\"") {
        let (h, plans, _) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("pla")
        field.returnKey()
        expectEqual(h.editor.editingShapeID, nil)
        let props = try require(h.reference(field.id))
        expectEqual(props.target, ReferenceTarget(id: plans, label: "Plan B"))
        expectEqual(props.words, "")
        expectEqual(props.query, nil)
        expectEqual(props.frame.width, ReferenceEdits.width(of: props))
        expect(props.frame.width < 120, "fit to the name, not the placed width: \(props.frame.width)")
        expectEqual(h.state(of: field.id).map { if case .live = $0 { true } else { false } }, true)
        expectEqual(h.editor.topology?.standIns(for: plans), [field.id], "it stands for it in the commit that picked")
        expectEqual(h.editor.undoHistory.undoName, "Add Reference")
        h.editor.undo()
        expectEqual(h.editor.document[field.id], nil, "placing, typing and picking are one step")
    },

    test("Tab picks the highlighted shape too, and so does a click on a row") {
        let (h, plans, pricing) = try setUp()
        let tab = try h.placeReference()
        defer { tab.close() }
        tab.type("pri")
        tab.tab()
        expectEqual(h.reference(tab.id)?.target?.id, pricing)
        expectEqual(h.editor.editingShapeID, nil)

        let click = try h.placeReference(at: CGPoint(x: 600, y: 300))
        defer { click.close() }
        click.type("plan")
        let rows = try require(click.list?.contentView?.descendants.first { $0.accessibilityRole() == .list })
        let index = try require(click.rows.firstIndex { $0.item?.title == "Plan B" })
        let point = rows.convert(CGPoint(x: 100, y: CGFloat(index) * 24 + 12), to: nil)
        let event = try require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                                                   windowNumber: click.list?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        rows.mouseDown(with: event)
        expectEqual(h.reference(click.id)?.target?.id, plans)
        expectEqual(h.editor.editingShapeID, nil)
    },

    test("↓ and ↑ move the highlight, wrapping, through the shapes and the words row; Return then picks the row it's on") {
        let (h, _, pricing) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("pri")
        let rows = field.rows.compactMap(\.item).map(\.title)
        expectEqual(rows, ["Pricing and plans", "pri"])
        field.down()
        expectEqual(field.list?.list.highlightedItem?.title, "pri")
        field.down()
        expectEqual(field.list?.list.highlightedItem?.title, "Pricing and plans", "wrapped")
        field.up()
        expectEqual(field.list?.list.highlightedItem?.title, "pri", "wrapped back")
        field.up()
        field.returnKey()
        expectEqual(h.reference(field.id)?.target?.id, pricing)
    },

    test("Return on the words row commits the words, shapes matching them or not; nothing is picked, and nothing is interpreted") {
        let (h, _, _) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("pri")
        field.down()
        field.returnKey()
        expectEqual(h.editor.editingShapeID, nil)
        let props = try require(h.reference(field.id))
        expectEqual(props.target, nil)
        expectEqual(props.words, "pri")
        expectEqual(props.query, nil, "words stay not interpreted")
        expectEqual(h.state(of: field.id), .notInterpreted(text: "pri"))
        expectEqual(h.editor.undoHistory.undoName, "Add Reference")
        expectEqual(props.frame.width, ReferenceEdits.width(of: props))
    },

    test("once only the words row is left, Return commits the words, and the pill leads with the magnifier while it's still edited") {
        let (h, _, _) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("plan")
        expect(field.rows.compactMap(\.item).count > 1, "shapes match")
        expectEqual(h.editor.references?.isHandingOff(field.id), false, "shapes still match: no hand-off")
        field.type("zq")
        expectEqual(field.titles, ["planzq"])
        expectEqual(h.editor.references?.isHandingOff(field.id), true, "the pill leads with the magnifier")
        let inset = (field.textView.textContainerInset.width)
        expectEqual(inset, 10 + 16 + 6, "the text moved over for the symbol")
        field.returnKey()
        expectEqual(h.reference(field.id)?.words, "planzq")
        expectEqual(h.editor.references?.isHandingOff(field.id), false, "over with editing")
    },

    test("⌥Return commits the words as typed even while shapes match them, picking nothing") {
        let (h, _, _) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("plan")
        expect(field.titles.count > 1, "shapes match")
        field.returnKey(.option)
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.reference(field.id)?.words, "plan")
        expectEqual(h.reference(field.id)?.target, nil)
        expectEqual(h.editor.undoHistory.undoName, "Add Reference")
    },

    test("⇧Return does nothing: the pill is one line, the list stays and the text is as it was") {
        let (h, _, _) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("plan")
        field.returnKey(.shift)
        expectEqual(h.editor.editingShapeID, field.id)
        expectEqual(field.textView.string, "plan")
        expect(field.list != nil)
    },

    test("Escape closes the list and keeps the field; a second Escape leaves it, the text typed kept as the pill's words; typing reopens the list") {
        let (h, _, _) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("plan")
        field.escape()
        expectEqual(h.editor.editingShapeID, field.id, "still editing")
        expectEqual(field.list == nil, true, "the list is closed")
        expect(!field.textView.holdsKeys)
        field.type("s")
        expect(field.list != nil, "typing reopened it")
        expectEqual(field.titles.last, "plans")
        field.escape()
        expectEqual(field.list == nil, true)
        field.escape()
        expectEqual(h.editor.editingShapeID, nil, "the second Escape leaves")
        expectEqual(h.reference(field.id)?.words, "plans", "non-empty text is never thrown away: it's the pill's words")
        expectEqual(h.reference(field.id)?.target, nil, "nothing was picked implicitly")
        expectEqual(h.editor.undoHistory.undoName, "Add Reference")
    },

    test("Return with the list closed leaves the field the same way: the text is the pill's words") {
        let (h, _, _) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("plan")
        field.escape()
        field.returnKey()
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.reference(field.id)?.words, "plan")
        expectEqual(h.reference(field.id)?.target, nil)
    },

    test("⌘Return leaves the field with the list open, picking nothing: typed text stays as the pill's words, and a pill opened and left unchanged is as it was") {
        let (h, plans, _) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("plan")
        field.returnKey(.command)
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.reference(field.id)?.words, "plan")
        expectEqual(h.reference(field.id)?.target, nil, "shapes matched, none was picked")

        let id = h.addReference(to: plans, label: "Plan B", at: CGPoint(x: 600, y: 300))
        let steps = h.editor.undoHistory.undoName
        let again = try h.editReference(id)
        defer { again.close() }
        again.returnKey(.command)
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.reference(id)?.target?.id, plans, "still the shape's")
        expectEqual(h.editor.undoHistory.undoName, steps, "no step")
    },

    test("leaving as the keyboard goes (a click elsewhere) commits the changed text as words, without the white space at its ends, in the step") {
        let (h, _, _) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("plan ")
        expectEqual(h.reference(field.id)?.words, "plan ", "as typed while it's typed")
        field.window.makeFirstResponder(nil)
        h.editor.endEditing()
        expectEqual(h.reference(field.id)?.words, "plan")
        expectEqual(h.reference(field.id)?.target, nil)
        expectEqual(h.editor.undoHistory.undoName, "Add Reference")
    },

    test("a new pill left empty is discarded as editing ends, with no step; white space alone is empty") {
        let (h, _, _) = try setUp()
        let steps = h.editor.undoHistory.undoName
        let field = try h.placeReference()
        defer { field.close() }
        field.type("  ")
        expectEqual(h.reference(field.id)?.mode, .empty, "white space is nothing")
        field.escape()
        field.escape()
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.document[field.id], nil)
        expectEqual(h.editor.undoHistory.undoName, steps, "and no step is left")
    },

    test("a pill with text typed is never discarded: emptied and typed again, it's kept; Return on the state row of an empty file discards") {
        let h = try referenceHarness()
        let field = try h.placeReference()
        defer { field.close() }
        expectEqual(field.rows, [.empty("No public shapes")])
        field.type("abc")
        expectEqual(field.titles, ["abc"])
        field.press("\u{7f}", code: 51)
        field.press("\u{7f}", code: 51)
        field.press("\u{7f}", code: 51)
        expectEqual(field.rows, [.empty("No public shapes")], "emptied, the state row again")
        field.type("x")
        field.escape()
        field.escape()
        expectEqual(h.reference(field.id)?.words, "x", "kept")

        let steps = h.editor.undoHistory.undoName
        let other = try h.placeReference(at: CGPoint(x: 600, y: 300))
        defer { other.close() }
        other.returnKey()
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.document[other.id], nil, "nothing was typed or picked")
        expectEqual(h.editor.undoHistory.undoName, steps)
    },

    test("editing again starts with what the pill says, all selected, the list open filtered by it; picking another shape re-points it as \"Edit Reference\"") {
        let (h, plans, pricing) = try setUp()
        let id = h.addReference(to: plans, label: "Plan B")
        let field = try h.editReference(id)
        defer { field.close() }
        expectEqual(field.textView.string, "Plan B")
        expectEqual(field.textView.selectedRange(), NSRange(location: 0, length: 6), "selected: typing replaces it")
        expectEqual(field.titles.first, "Plan B", "filtered by it")
        field.type("pri")
        expectEqual(h.reference(id)?.words, "pri", "typing over its name makes it words")
        expectEqual(h.reference(id)?.target, nil)
        field.returnKey()
        expectEqual(h.reference(id)?.target?.id, pricing)
        expectEqual(h.editor.undoHistory.undoName, "Edit Reference")
        expectEqual(h.editor.topology?.standIns(for: plans), [])
        expectEqual(h.editor.topology?.standIns(for: pricing), [id])
    },

    test("Return on a pill opened and left alone keeps what it stands for, though another shape is called alike and nearer: its row is the highlighted one") {
        let h = try referenceHarness()
        let far = h.addBox("Plan B", at: CGRect(x: 1500, y: 1500, width: 150, height: 100))
        _ = h.addBox("Plan B", at: CGRect(x: 420, y: 360, width: 150, height: 100))
        let id = h.addReference(to: far, label: "Plan B")
        let steps = h.editor.undoHistory.undoName
        let field = try h.editReference(id)
        defer { field.close() }
        expectEqual(field.titles, ["Plan B", "Plan B", "Plan B"], "two shapes and the words")
        expectEqual(field.list?.list.highlighted, 1, "the far one's row: the nearer ranks first")
        field.returnKey()
        expectEqual(h.reference(id)?.target?.id, far, "still the far one")
        expectEqual(h.editor.undoHistory.undoName, steps)
    },

    test("text that's the same as the field opened with makes no step: left at once, or typed over and typed back") {
        let (h, plans, _) = try setUp()
        let id = h.addReference(to: plans, label: "Plan B")
        let before = h.editor.document
        let steps = h.editor.undoHistory.undoName
        let still = try h.editReference(id)
        still.escape()
        still.escape()
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.undoHistory.undoName, steps, "no step")
        still.close()

        let back = try h.editReference(id)
        defer { back.close() }
        back.type("x")
        expectEqual(h.reference(id)?.words, "x")
        back.textView.setSelectedRange(NSRange(location: 0, length: 1))
        back.type("Plan B")
        expectEqual(back.textView.string, "Plan B")
        expectEqual(h.reference(id)?.target?.id, plans, "typed back to what it said: it's what it was")
        back.escape()
        back.escape()
        expectEqual(h.editor.undoHistory.undoName, steps, "no step")
        expectEqual(h.editor.document, before)
    },

    test("emptied on a pill that said something, it's put back as it was and kept") {
        let (h, plans, _) = try setUp()
        let id = h.addReference(to: plans, label: "Plan B")
        let field = try h.editReference(id)
        defer { field.close() }
        field.press("\u{7f}", code: 51)
        expectEqual(field.textView.string, "")
        expectEqual(h.reference(id)?.target?.id, plans)
        field.escape()
        field.escape()
        expect(h.editor.document[id] != nil)
        expectEqual(h.reference(id)?.target?.id, plans)
    },

    test("at most 200 characters; pasted line breaks and tabs are spaces") {
        let h = try referenceHarness()
        let field = try h.placeReference()
        defer { field.close() }
        field.textView.insertText(String(repeating: "a", count: 150), replacementRange: NSRange(location: 0, length: 0))
        field.textView.insertText(String(repeating: "b", count: 100), replacementRange: NSRange(location: 150, length: 0))
        expectEqual((field.textView.string as NSString).length, 200)
        expectEqual(h.reference(field.id)?.words.count, 200)
        field.textView.insertText("c", replacementRange: NSRange(location: 200, length: 0))
        expectEqual((field.textView.string as NSString).length, 200, "a character more is nothing")
        field.textView.setSelectedRange(NSRange(location: 0, length: 200))
        field.textView.insertText("two\nlines\tand more\r\nhere", replacementRange: field.textView.selectedRange())
        expectEqual(field.textView.string, "two lines and more here")
    },

    test("a pick is remembered as recent: the next list for nothing typed starts with it") {
        let (h, _, pricing) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("pri")
        field.returnKey()
        let next = try h.placeReference(at: CGPoint(x: 600, y: 300))
        defer { next.close() }
        expectEqual(next.titles.first, "Pricing and plans")
        expectEqual(h.reference(field.id)?.target?.id, pricing)
    },

    test("the list sits under the start of the text, and follows it as the pill moves") {
        let (h, _, _) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("pla")
        let list = try require(field.list)
        let text = field.textView.firstRect(forCharacterRange: NSRange(location: 0, length: 3), actualRange: nil)
        expect(abs(list.frame.minX - (text.minX - 5 - 7)) < 1.5, "its rows' text under the text's start: \(list.frame.minX) for \(text.minX)")
        expect(list.frame.maxY <= text.minY + 1, "below it")
        expectEqual(list.frame.width, 280)
        expectEqual(list.frame.height, CGFloat(field.rows.count) * 24 + 10)
        field.escape()
        expectEqual(field.list == nil, true)
    },

    test("what the list says in each state is said by VoiceOver: a shape's label, kind and place; the words") {
        let (h, _, _) = try setUp()
        let field = try h.placeReference()
        defer { field.close() }
        field.type("pri")
        let spoken = field.rows.compactMap(\.item).map(\.spoken)
        expect(spoken.first?.hasPrefix("Pricing and plans, ") == true && spoken.first?.hasSuffix(", 1 of 1") == true, "\(spoken)")
        expectEqual(spoken.last, "Words, pri")
    },

    test("the field doesn't turn quotes or dashes into curly ones: words are typed as they are") {
        let h = try referenceHarness()
        let field = try h.placeReference()
        defer { field.close() }
        expect(!field.textView.isAutomaticQuoteSubstitutionEnabled && !field.textView.isAutomaticDashSubstitutionEnabled)
        field.type("\"Auth\" -- x")
        expectEqual(h.reference(field.id)?.words, "\"Auth\" -- x")
    },
])
