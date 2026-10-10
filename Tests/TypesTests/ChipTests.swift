import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import Keyboard
import Selection
import TestKit
import Titles
import Types

// A shape's types as chips above its top-left corner, after its title's pill: one for each type, in
// the order of its list, with its type's live title, light in its type's color; none on a type that
// is none (its pill is Titles' own); "+N" for those that don't fit; and what a click on one opens. Over memos, which are titled, in an editor with no view: the chips are
// laid out against the shape's bounds, in world units.

/// The labels of a shape's adornments in the row, in order, as `adornmentFrames` lays them out.
@MainActor private func chips(_ editor: CanvasEditor, _ id: ShapeID) -> [AdornmentFrame] {
    editor.adornmentFrames(of: id).filter { $0.adornment == .of(TypeChips.self) }
}

@MainActor private func texts(_ editor: CanvasEditor, _ id: ShapeID) -> [String] {
    chips(editor, id).map { $0.label.text ?? "" }
}

/// A click on the chip with this text, as the canvas passes it to the adornment.
@MainActor private func click(_ editor: CanvasEditor, _ id: ShapeID, _ text: String) throws -> AdornmentClick {
    let frame = try require(chips(editor, id).first { $0.label.text == text }, "no chip \(text): \(texts(editor, id))")
    return AdornmentClick(shape: id, tag: frame.tag, rect: frame.rect, isOverflow: frame.isOverflow)
}

/// The titles of a menu's items, in order ("-" for a separator).
@MainActor private func items(_ menu: NSMenu?) -> [String] {
    (menu?.items ?? []).map { $0.isSeparatorItem ? "-" : $0.title }
}

/// What the editor would pop up for a click now, and clears it.
@MainActor private func poppedUp(_ editor: CanvasEditor, after click: AdornmentClick) -> (menu: NSMenu, rect: CGRect)? {
    TypeChips.click(click, in: editor)
    defer { editor.menuDidPopUp() }
    return editor.menuToPopUp
}

@MainActor let chipTests = Suite("Type chips", [
    test("an instance has a chip for each type, in the order of its list, with the type's title, light in the type's color; a type that is none, and a shape that is none, have none") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), employee = editor.addType(TypeSchemaProperty.starter, title: "Employee")
        let ann = editor.addInstance("Ann", of: [employee, person], title: "Ann")
        let plain = editor.add(memo("plain", at: CGPoint(x: 600, y: 40)))
        expectEqual(texts(editor, person), [], "no Type chip")
        expectEqual(editor.adornmentFrames(of: person).map { $0.label.text ?? "" }, ["Person"], "the title's pill alone")
        expectEqual(editor.adornmentFrames(of: ann).map { $0.label.text ?? "" }, ["Ann", "Employee", "Person"])
        expectEqual(texts(editor, ann), ["Employee", "Person"])
        expectEqual(chips(editor, plain), [])
        expect(chips(editor, ann).allSatisfy { $0.rect.minY < 400 && !$0.label.isMissing }, "above the top edge")
        let a = chips(editor, ann)
        expect(a[0].rect.maxX < a[1].rect.minX, "side by side: \(a.map(\.rect))")
        expectEqual(a.map(\.tag), [AdornmentTag(employee), AdornmentTag(person)], "told apart by the type they stand for")
        expectEqual(a.map(\.label.tint), [TypeColors.light(employee), TypeColors.light(person)], "each in its type's color")
        expect(a.allSatisfy { $0.label.tint?.style == .light }, "light")
        // A type that is an instance: the pill, then the chips of the types it builds on.
        editor.addTypeLink(person, to: employee)
        expectEqual(texts(editor, employee), ["Person"])
        expectEqual(editor.adornmentFrames(of: employee).map { $0.label.text ?? "" }, ["Employee", "Person"], "its pill, then the chip")
        expectEqual(editor.adornmentFrames(of: employee).first?.label.tint, TypeColors.solid(employee), "the pill is solid, in its own color")
    },
    test("a chip reads its type's live title: renamed, it changes; untitled, it says so; undone, it is back") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), draft = editor.addType(TypeSchemaProperty.starter)
        let ann = editor.addInstance("Ann", of: [person, draft])
        expectEqual(texts(editor, ann), ["Person", "Untitled"])
        expect(chips(editor, ann)[1].label.isPlaceholder, "an untitled type reads as a placeholder")
        expectEqual(chips(editor, ann)[1].label.tint, nil, "gray: no color")
        expect(chips(editor, ann)[0].label.tint != nil)
        editor.transact("Rename") { $0.update(person) { $0[TitleProperty.self] = "Human" } }
        expectEqual(texts(editor, ann), ["Human", "Untitled"])
        editor.undo()
        expectEqual(texts(editor, ann), ["Person", "Untitled"])
    },
    test("a type that is gone is a dashed chip with the last title it was known by; back whole when the delete is undone; one the index never knew says Deleted") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person, ShapeID()])
        editor.transact("Delete") { $0.delete([person]) }
        expectEqual(texts(editor, ann), ["Person", "Deleted"])
        expect(chips(editor, ann).allSatisfy { $0.label.isMissing && $0.label.tint == nil }, "dashed, gray")
        editor.undo()
        expectEqual(texts(editor, ann).first, "Person")
        expectEqual(chips(editor, ann).map(\.label.isMissing), [false, true])
        // No longer a type is gone as a chip says it, until it is one again.
        editor.removeType(person)
        expectEqual(chips(editor, ann).map(\.label.isMissing), [true, true])
        editor.undo()
        expectEqual(chips(editor, ann).map(\.label.isMissing), [false, true])
    },
    test("chips that don't fit whole fold, with those after them, into one \"+N\" chip") {
        let editor = try typeEditor()
        let names = ["Person", "Employee", "Manager", "Contractor", "Director", "Intern"]
        let types = names.map { editor.addType(TypeSchemaProperty.starter, title: $0, at: CGPoint(x: 600, y: 40 + CGFloat(names.firstIndex(of: $0)!) * 80)) }
        let ann = editor.addInstance("", of: types)
        let frames = chips(editor, ann)
        let overflow = try require(frames.first { $0.isOverflow }, "a +N: \(texts(editor, ann))")
        let shown = frames.filter { !$0.isOverflow }
        expect(!shown.isEmpty && shown.count < names.count, "some chips are whole: \(texts(editor, ann))")
        expectEqual(shown.map { $0.label.text ?? "" }.prefix(shown.count - 1), names.prefix(shown.count - 1), "in order")
        expectEqual(overflow.label.text, "+\(names.count - shown.count)")
        expect(overflow.rect.minX > shown.last!.rect.maxX, "after the chips that fit")
        expectEqual(overflow.tag, nil)
    },
    test("a click on a type's chip opens a menu below the chip: Go to it and Remove it; Go to selects the type, Remove takes it out in one step") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 600, y: 40))
        let ann = editor.addInstance("Ann", of: [person])
        let hit = try click(editor, ann, "Person")
        let (menu, rect) = try require(poppedUp(editor, after: hit))
        expectEqual(items(menu), ["Go to “Person”", "Remove “Person”"])
        expectEqual(rect, chips(editor, ann)[0].rect, "below the chip's rect")
        menu.performActionForItem(at: 0)
        expectEqual(editor.selectedShapeIDs, [person])
        _ = poppedUp(editor, after: hit)
        let (again, _) = try require(poppedUp(editor, after: hit))
        again.performActionForItem(at: 1)
        expectEqual(editor.typesOf(ann), [])
        expectEqual(editor.undoHistory.undoName, "Remove Type")
        expectEqual(texts(editor, ann), [])
        editor.undo()
        expectEqual(editor.typesOf(ann), [person])
    },
    test("on a read-only shape the menu has Go to alone; for a type that is gone, Remove alone") {
        let editor = try typeEditor(more: [FreezingPlugin()])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), gone = editor.addType(TypeSchemaProperty.starter, title: "Gone")
        let ann = editor.addInstance("Ann", of: [person, gone])
        editor.transact("Delete") { $0.delete([gone]) }
        expectEqual(items(poppedUp(editor, after: try click(editor, ann, "Gone"))?.menu), ["Remove “Gone”"])
        editor.freeze([ann])
        expectEqual(items(poppedUp(editor, after: try click(editor, ann, "Person"))?.menu), ["Go to “Person”"])
        expect(poppedUp(editor, after: try click(editor, ann, "Gone")) == nil, "nothing to offer, nothing opens")
    },
    test("the \"+N\" chip's menu lists every type the shape is, each with its Go to and Remove") {
        let editor = try typeEditor()
        let names = ["Person", "Employee", "Manager", "Contractor", "Director", "Intern"]
        let types = names.map { editor.addType(TypeSchemaProperty.starter, title: $0, at: CGPoint(x: 600, y: 40 + CGFloat(names.firstIndex(of: $0)!) * 80)) }
        let ann = editor.addInstance("", of: types)
        let overflow = try require(chips(editor, ann).first { $0.isOverflow })
        let hit = AdornmentClick(shape: ann, tag: nil, rect: overflow.rect, isOverflow: true)
        let menu = try require(poppedUp(editor, after: hit)?.menu)
        expectEqual(items(menu), names.enumerated().flatMap { index, name in
            (index > 0 ? ["-"] : []) + ["Go to “\(name)”", "Remove “\(name)”"]
        })
        // The last type's Remove: items are Go to, Remove, a separator, Go to, Remove, ...
        menu.performActionForItem(at: menu.items.count - 1)
        expectEqual(editor.typesOf(ann), Array(types.dropLast()))
    },
    test("none zoomed out, where the canvas draws a skeleton; back at 35%") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 100, y: 100))
        editor.camera = Camera(origin: .zero, zoom: 0.3)
        expectEqual(chips(editor, ann), [])
        expectEqual(chips(editor, person), [])
        editor.camera = Camera(origin: .zero, zoom: 0.35)
        expectEqual(texts(editor, ann), ["Person"])
    },
    test("a click on a chip with the pointer is the chip's: the canvas passes the shape, the tag and the rect, and the menu is below it") {
        let h = try EditorHarness(plugins: typePlugins())
        let person = h.editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 600, y: 300))
        let ann = h.editor.addInstance("Ann", of: [person], at: CGPoint(x: 100, y: 300))
        let chip = try require(chips(h.editor, ann).first)
        let center = h.editor.camera.toView(chip.rect).center
        h.click(at: center)
        let (menu, rect) = try require(h.editor.menuToPopUp)
        expectEqual(items(menu), ["Go to “Person”", "Remove “Person”"])
        expectEqual(rect, chip.rect)
        expect(h.editor.selectedShapeIDs.isEmpty, "a chip is a button: the shape isn't selected by it")
    },
])
