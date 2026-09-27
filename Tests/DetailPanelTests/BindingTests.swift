import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Selection
import SwiftUI
import TestKit

// The panel's one write path: snapshot reads (and, after a write, what it made of the shape),
// key-path writes onto the live shape.
@MainActor let bindingTests = Suite("Shape bindings", [
    test("a field write is one transaction and changes only that field") {
        let editor = try gadgetEditor()
        let id = editor.add(Gadget(gadgetFrame, name: "Old"))
        let gadget = try require(editor.shapeBinding(id, as: Gadget.self))
        let revision = editor.revision
        gadget.name.wrappedValue = "New"
        expectEqual(editor.revision, revision + 1)
        expectEqual(editor.props(id, as: Gadget.self), Gadget(gadgetFrame, name: "New"))
    },
    test("reads are the snapshot; a write lands on the live shape, so a later move survives a rename") {
        let editor = try gadgetEditor()
        let id = editor.add(Gadget(gadgetFrame, name: "Old"))
        let gadget = try require(editor.shapeBinding(id, as: Gadget.self))
        let moved = CGRect(x: 500, y: 500, width: 240, height: 160)
        editor.transact { $0.update(id) { $0.box = moved } }
        expectEqual(gadget.wrappedValue.frame, gadgetFrame)
        gadget.name.wrappedValue = "New"
        expectEqual(editor.props(id, as: Gadget.self), Gadget(moved, name: "New"))
    },
    test("two writes in one action both land") {
        let editor = try gadgetEditor()
        let id = editor.add(Gadget(gadgetFrame))
        let gadget = try require(editor.shapeBinding(id, as: Gadget.self))
        gadget.mode.wrappedValue = .fancy
        gadget.count.wrappedValue = 3
        expectEqual(editor.props(id, as: Gadget.self)?.mode, .fancy)
        expectEqual(editor.props(id, as: Gadget.self)?.count, 3)
    },
    test("update makes several changes in one transaction, to the live value") {
        let editor = try gadgetEditor()
        let id = editor.add(Gadget(gadgetFrame))
        let gadget = try require(editor.shapeBinding(id, as: Gadget.self))
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.count = 5 } }
        let revision = editor.revision
        gadget.update {
            $0.count += 1
            $0.parts.append(Gadget.Part(text: "wheel"))
        }
        expectEqual(editor.revision, revision + 1)
        expectEqual(editor.props(id, as: Gadget.self)?.count, 6)
        expectEqual(editor.props(id, as: Gadget.self)?.parts.map(\.text), ["wheel"])
    },
    test("a binding reads back what its writes made of the shape, before the panel draws again; the snapshot stays as drawn") {
        let editor = try gadgetEditor()
        let id = editor.add(Gadget(gadgetFrame, name: "Old"))
        let gadget = try require(editor.shapeBinding(id, as: Gadget.self))
        let name = gadget.name
        name.wrappedValue = "New"
        expectEqual(name.wrappedValue, "New", "not the snapshot's Old")
        expectEqual(gadget.name.wrappedValue, "New")
        // Changed elsewhere meanwhile: an update reads back the live shape, not the snapshot plus its change.
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.count = 5 } }
        gadget.update { $0.count += 1 }
        expectEqual(gadget.count.wrappedValue, 6)
        expectEqual(gadget.wrappedValue.name, "Old", "the snapshot the panel drew with")

        let frame = try require(editor.frameBinding(id))
        frame.origin.x.wrappedValue = 10
        expectEqual(frame.origin.x.wrappedValue, 10)
        expectEqual(frame.wrappedValue.origin.x, gadgetFrame.origin.x)
    },
    test("writing the value the shape already has commits nothing") {
        let editor = try gadgetEditor()
        let id = editor.add(Gadget(gadgetFrame, name: "Same"))
        let gadget = try require(editor.shapeBinding(id, as: Gadget.self))
        let revision = editor.revision
        gadget.name.wrappedValue = "Same"
        gadget.update { _ in }
        expectEqual(editor.revision, revision)
    },
    test("a binding keeps writing to its shape after the selection moves") {
        let editor = try gadgetEditor()
        let a = editor.add(Gadget(gadgetFrame, name: "A")), b = editor.add(Gadget(gadgetFrame, name: "B"))
        editor.selection = a
        let gadget = try require(editor.shapeBinding(a, as: Gadget.self))
        editor.selection = b
        gadget.name.wrappedValue = "A2"
        expectEqual(editor.props(a, as: Gadget.self)?.name, "A2")
        expectEqual(editor.props(b, as: Gadget.self)?.name, "B")
    },
    test("writing to a deleted shape does nothing") {
        let editor = try gadgetEditor()
        let id = editor.add(Gadget(gadgetFrame))
        let gadget = try require(editor.shapeBinding(id, as: Gadget.self))
        let frame = try require(editor.frameBinding(id))
        editor.transact { $0.delete([id]) }
        let revision = editor.revision
        gadget.name.wrappedValue = "Ghost"
        frame.origin.x.wrappedValue = 1
        expectEqual(editor.revision, revision)
        expect(editor.document.shapes.isEmpty)
    },
    test("a frame binding: Width keeps the left edge; X moves the box") {
        let editor = try gadgetEditor()
        let id = editor.add(Box(gadgetFrame))
        try require(editor.frameBinding(id)).size.width.wrappedValue = 300
        expectEqual(editor.document[id]?.box, CGRect(x: 80, y: 40, width: 300, height: 160))
        try require(editor.frameBinding(id)).origin.x.wrappedValue = 10
        expectEqual(editor.document[id]?.box, CGRect(x: 10, y: 40, width: 300, height: 160))
    },
    test("there's no binding for a shape of another kind, and no frame binding for a shape without one") {
        let editor = try gadgetEditor()
        let box = editor.add(Box(gadgetFrame)), tag = editor.add(Tag(target: nil))
        expect(editor.shapeBinding(box, as: Gadget.self) == nil)
        expect(editor.shapeBinding(box, as: Box.self) != nil)
        expect(editor.frameBinding(tag) == nil)
        expect(editor.frameBinding(ShapeID()) == nil)
    },
    test("number text formats without grouping, and parses a number with or without its unit") {
        expectEqual(DetailNumberText.format(240, unit: "pt"), "240 pt")
        expectEqual(DetailNumberText.format(12_345.5, unit: "pt"), "12345.5 pt")
        expectEqual(DetailNumberText.format(2.25, unit: ""), "2.25")
        expectEqual(DetailNumberText.format(1.0 / 3, unit: "h"), "0.33 h")
        expectEqual(DetailNumberText.format(-3, unit: "h"), "-3 h")
        expectEqual(DetailNumberText.parse("240"), 240)
        expectEqual(DetailNumberText.parse("240pt"), 240)
        expectEqual(DetailNumberText.parse(" 240 pt "), 240)
        expectEqual(DetailNumberText.parse("-12.5 pt"), -12.5)
        expectEqual(DetailNumberText.parse("pt"), nil)
        expectEqual(DetailNumberText.parse(""), nil)
        expectEqual(DetailNumberText.parse("1.2.3"), nil)
        expectEqual(DetailNumberText.parse(String(repeating: "9", count: 400)), nil)
    },
    test("number text reads back what it shows, in any locale, and takes a typed point as a decimal point") {
        for identifier in ["en_US", "de_DE", "sv_SE", "ar_EG", "de_CH"] {
            let locale = Locale(identifier: identifier)
            for value in [2.5, -40, 0.25, 1234.5] {
                let shown = DetailNumberText.format(value, unit: "h", locale: locale)
                expectEqual(DetailNumberText.parse(shown, locale: locale), value, "\(identifier): \(shown)")
            }
            expectEqual(DetailNumberText.parse("2.5", locale: locale), 2.5, identifier)
        }
        let german = Locale(identifier: "de_DE")
        expectEqual(DetailNumberText.format(2.5, unit: "h", locale: german), "2,5 h")
        expectEqual(DetailNumberText.parse("3,5", locale: german), 3.5)
        expectEqual(DetailNumberText.parse("1,2,3", locale: german), nil)
    },
])
