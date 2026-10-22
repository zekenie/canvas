import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Draw
import Foundation
import Geometry
import Mentions
import Selection
import TestKit
import Titles
import Types
import Validation

// The card that defines a relationship type (`DefinitionCards`, `DefinitionView`): opened by a call and by Tab in the pill's
// name, shown in a `CanvasView` in an unshown window so the host's part (the place, the keyboard, a press elsewhere) is the real
// one. Its name, its fields, `add field` and a kind picked, its options, the end lines, and what each step writes and undoes.

/// Car and Person with a relationship type between them (`owner`), the card host around them.
@MainActor private final class DefinitionRig {
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView
    let car: ShapeID, person: ShapeID, hub: ShapeID
    let fromEnd: ShapeID, toEnd: ShapeID
    var cards: DefinitionCards { editor.definitionCards! }

    init(title: String? = "owner", log: RefusalLog? = nil) throws {
        editor = try bondEditor(more: [DrawPlugin(), TitleNamesPlugin(), TypeNamesPlugin(), FieldValuesPlugin(), ValidationChecksPlugin(), BondEdgesPlugin()]
                                + (log.map { [FreezingPlugin(log: $0)] } ?? []))
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        car = editor.addType(TypeSchemaProperty.starter, title: "car", at: CGPoint(x: 40, y: 40))
        person = editor.addType(TypeSchemaProperty.starter, title: "person", at: CGPoint(x: 560, y: 40))
        let bond = editor.addBond(car, person)
        let made = try require(editor.newRelationshipType(from: car, to: person, replacing: bond))
        hub = made
        if let title { editor.transact("Name") { $0.update(made) { $0[TitleProperty.self] = title } } }
        let sides = try require(editor.relationships?.graph.sides(of: made))
        fromEnd = try require(sides.from.first).carrier
        toEnd = try require(sides.to.first).carrier
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas = CanvasView(editor: editor)
        window.contentView = canvas
        window.makeFirstResponder(canvas)
    }

    func close() { window.close() }

    @discardableResult
    func open(at stop: DefinitionStop? = nil) -> Bool { cards.open(hub, focus: stop) }

    var view: DefinitionView? { cards.openView }
    var inEditor: Bool { view.map { window.firstResponder === $0.cellEditor } ?? false }
    var inCard: Bool { view.map { window.firstResponder === $0 } ?? false }
    var fields: [DefinedField] { editor.fieldDefiner?.fields(of: hub) ?? [] }
    var undoName: String? { editor.undoHistory.undoName }
    func tab() { window.press("\t", code: 48) }
    func backtab() { window.press("\u{19}", code: 48, modifiers: .shift) }
    func down() { window.press("\u{F701}", code: 125) }
    func up() { window.press("\u{F700}", code: 126) }
    func space() { window.press(" ", code: 49) }
    func title() -> String? { editor.shape(inFile: hub)?[TitleProperty.self] }
    func said(_ end: ShapeID) -> String? { editor.shape(inFile: end)?.typed(as: Bond.self)?.props.text.firstLine }
}

@MainActor let definitionCardTests = Suite("The card that defines a relationship type", [
    test("it opens under the pill, about the type, selected, with the caret in its name; the lines are the name, add field, a hairline and an end each") {
        let r = try DefinitionRig()
        defer { r.close() }
        expect(r.open())
        let card = try require(r.editor.card)
        expectEqual(card.shape, r.hub)
        expectEqual(card.anchor, r.editor.frame(inFile: r.hub))
        expectEqual(card.stepName, nil, "it holds no step: each write is its own")
        expectEqual(r.editor.selectedShapeIDs, [r.hub])
        let view = try require(r.view)
        expect(r.canvas.cardView === view)
        expectEqual(view.focus, .title)
        expect(r.inEditor)
        expectEqual(view.title, "owner")
        expectEqual(view.stops, [.title, .addField, .endName(r.fromEnd), .needed(r.fromEnd), .onlyOne(r.fromEnd),
                                 .endName(r.toEnd), .needed(r.toEnd), .onlyOne(r.toEnd)])
        expect(!r.editor.canUndo || r.undoName == TypesStyle.newRelationshipType || r.undoName == "Name", "opening makes no step")
        r.cards.close()
        expect(r.editor.card == nil && r.cards.openType == nil)
        expect(r.window.firstResponder === r.canvas, "the keyboard is back where it was")
    },
    test("a card of a shape that is no relationship type, or not on the board, does not open; asked again while open it closes") {
        let r = try DefinitionRig()
        defer { r.close() }
        expect(!r.cards.open(r.car), "a plain type")
        expect(!r.cards.open(ShapeID()), "a shape that is not there")
        expect(r.open())
        expect(r.open(), "asked again it closes")
        expect(r.editor.card == nil)
    },
    test("the whole flow is a step each: add field, type since, Tab (it is added as Text and its kinds are listed), pick Date, Return; each Undo takes back exactly one") {
        let r = try DefinitionRig()
        defer { r.close() }
        expect(r.open(at: .addField))
        expect(r.inEditor)
        let before = r.editor.document
        r.window.type("since")
        r.tab()
        expectEqual(r.fields.map(\.name), ["since"])
        expectEqual(r.fields.first?.kind, .text)
        expectEqual(r.undoName, FieldDefiner.Step.addField)
        let view = try require(r.view)
        expectEqual(view.focus, .fieldKind("since"))
        expectEqual(view.listing, "since", "its kinds are listed")
        expectEqual(view.highlight, 0, "Text is the one it has")
        expect(r.inCard, "a kind has the keyboard itself")
        r.down()
        r.down()
        expectEqual(view.highlight, 2)
        expectEqual(r.fields.first?.kind, .text, "nothing is written until Return")
        r.window.pressReturn()
        expectEqual(r.fields.first?.kind, .date)
        expectEqual(r.undoName, FieldDefiner.Step.changeKind)
        expectEqual(view.focus, .addField, "picking a kind moves on")
        expect(view.listing == nil)
        expect(r.inEditor)
        r.cards.close()
        r.editor.undo()
        expectEqual(r.fields.first?.kind, .text, "one Undo takes back the kind")
        r.editor.undo()
        expectEqual(r.fields, [], "and one the field")
        expectEqual(r.editor.document, before)
        r.editor.redo()
        r.editor.redo()
        expectEqual(r.fields.first?.kind, .date)
    },
    test("Return on a typed add field adds it too, and Return on a blank one closes the card") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.open(at: .addField)
        r.window.type("primary")
        r.window.pressReturn()
        expectEqual(r.fields.map(\.name), ["primary"])
        expectEqual(r.view?.focus, .fieldKind("primary"))
        r.window.pressEscape()
        expect(r.view?.listing == nil, "Esc closes the list first")
        expect(r.editor.card != nil)
        expectEqual(r.view?.focus, .addField)
        r.window.pressReturn()
        expect(r.editor.card == nil, "Return on a blank add field ends it")
    },
    test("renaming a field is one step when the caret leaves it, a kind changed from its line is one, and an emptied name removes the field in one") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.editor.fieldDefiner?.addField(named: "since", kind: .date, to: r.hub)
        r.open()
        r.tab()
        let view = try require(r.view)
        expectEqual(view.focus, .fieldName("since"))
        r.window.type("start")
        expectEqual(r.fields.first?.name, "since", "typing writes nothing")
        r.tab()
        expectEqual(r.fields.first?.name, "start")
        expectEqual(r.undoName, FieldDefiner.Step.renameField)
        expectEqual(view.focus, .fieldKind("since"), "the key stays; the kind is next")
        r.window.pressReturn()
        expectEqual(view.listing, "since")
        expectEqual(view.highlight, 2, "the list opens at its kind")
        r.up()
        r.window.pressReturn()
        expectEqual(r.fields.first?.kind, .number)
        expectEqual(r.undoName, FieldDefiner.Step.changeKind)
        expectEqual(view.focus, .fieldKind("since"))
        r.backtab()
        expectEqual(view.focus, .fieldName("since"))
        r.window.pressDelete()
        r.tab()
        expectEqual(r.fields, [])
        expectEqual(r.undoName, FieldDefiner.Step.removeField)
        expectEqual(view.focus, .addField, "the keyboard goes on to what slid into its place")
        r.editor.undo()
        expectEqual(r.fields.map(\.name), ["start"], "one Undo brings it back")
    },
    test("a Choice lists its options under it and an empty line that adds one; each option is a step, and one emptied is removed") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.open(at: .addField)
        r.window.type("color")
        r.tab()
        r.down()
        r.down()
        r.down()
        r.down()
        expectEqual(r.view?.highlight, 4)
        r.window.pressReturn()
        let view = try require(r.view)
        expectEqual(r.fields.first?.kind, .choice)
        expectEqual(view.focus, .newOption("color"), "a Choice goes on to its options")
        expect(r.inEditor)
        r.window.type("red")
        r.window.pressReturn()
        expectEqual(r.fields.first?.options, ["red"])
        expectEqual(r.undoName, FieldDefiner.Step.addOption)
        expectEqual(view.focus, .newOption("color"), "the empty line is there again")
        expectEqual(view.cellEditor.string, "")
        r.window.type("blue")
        r.window.pressReturn()
        expectEqual(r.fields.first?.options, ["red", "blue"])
        expectEqual(view.stops.filter { if case .option = $0 { true } else { false } }.count, 2)
        r.up()
        expectEqual(view.focus, .option("color", 1))
        r.window.type("navy")
        r.tab()
        expectEqual(r.fields.first?.options, ["red", "navy"])
        expectEqual(r.undoName, FieldDefiner.Step.renameOption)
        r.backtab()
        r.window.pressDelete()
        r.tab()
        expectEqual(r.fields.first?.options, ["red"])
        expectEqual(r.undoName, FieldDefiner.Step.removeOption)
    },
    test("the name is the title, typed in the card: one coalesced step, Name Relationship Type, which one Undo takes back") {
        let r = try DefinitionRig(title: nil)
        defer { r.close() }
        r.editor.undoHistory.group("Mark") {}
        r.open()
        let view = try require(r.view)
        expectEqual(view.title, "")
        r.window.type("own")
        expectEqual(r.title(), "own")
        r.window.type("er")
        expectEqual(r.title(), "owner")
        expectEqual(r.undoName, TypesStyle.nameRelationshipType)
        expectEqual(view.title, "owner", "the card read it again")
        r.cards.close()
        r.editor.undo()
        expectEqual(r.title(), nil, "one step for the whole name")
    },
    test("an end line's name is written as the end arrow's words in one coalesced step, Name Row, and the row follows; its placeholder is the row's derived name") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.open()
        let view = try require(r.view)
        expectEqual(view.ends.map(\.placeholder), ["owner", "car"], "car's row is named for the relationship, person's for the other type")
        r.tab()
        r.tab()
        expectEqual(view.focus, .endName(r.fromEnd))
        r.window.type("own")
        r.window.type("ed")
        expectEqual(r.said(r.fromEnd), "owned")
        expectEqual(r.undoName, TypesStyle.nameRow)
        let types = try require(r.editor.types)
        expectEqual(r.editor.relationships?.rows(for: [r.car], isType: false).first?.name(in: types.graph), "owned", "car's row is called owned now")
        r.cards.close()
        r.editor.undo()
        expectEqual(r.said(r.fromEnd), nil, "one Undo for what was typed")
    },
    test("Needed and Only one are checks on an end's line: Return or Space ticks, each through setEndRule's step; the rule is read back") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.open()
        let view = try require(r.view)
        view.focus(.needed(r.fromEnd))
        expect(r.inCard)
        r.window.pressReturn()
        expectEqual(r.undoName, TypesStyle.makeNeeded)
        expectEqual(r.editor.shape(inFile: r.fromEnd)?[RelationshipEndProperty.self]?.needed, true)
        expectEqual(view.ends.first?.rule.needed, true)
        r.tab()
        expectEqual(view.focus, .onlyOne(r.fromEnd))
        r.space()
        expectEqual(r.undoName, TypesStyle.allowOnlyOne)
        expectEqual(r.editor.shape(inFile: r.fromEnd)?[RelationshipEndProperty.self]?.onlyOne, true)
        expectEqual(r.editor.shape(inFile: r.toEnd)?[RelationshipEndProperty.self]?.onlyOne ?? false, false, "the other end is its own")
        r.space()
        expectEqual(r.undoName, TypesStyle.allowSeveral)
        view.focus(.needed(r.fromEnd))
        r.window.pressReturn()
        expectEqual(r.undoName, TypesStyle.makeOptional)
    },
    test("Tab runs the stops in order and goes off the last: the card closes; ⇧Tab off the first the same; Esc keeps what was typed and closes") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.open()
        r.backtab()
        expect(r.editor.card == nil, "off the first stop")
        r.open(at: .onlyOne(r.toEnd))
        r.tab()
        expect(r.editor.card == nil, "off the last")
        r.open()
        r.window.type("s")
        expectEqual(r.title(), "s", "the name is selected as the card opens")
        r.window.pressEscape()
        expect(r.editor.card == nil)
        expectEqual(r.title(), "s")
        r.open(at: .addField)
        r.window.type("since")
        r.window.pressEscape()
        expectEqual(r.fields.map(\.name), ["since"], "a field typed and left is added, as the caret leaving it does")
    },
    test("↑ and ↓ go by lines; a press elsewhere closes the card and keeps a field typed in it") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.open()
        r.down()
        expectEqual(r.view?.focus, .addField)
        r.down()
        expectEqual(r.view?.focus, .endName(r.fromEnd))
        r.up()
        expectEqual(r.view?.focus, .addField)
        r.window.type("since")
        r.canvas.pressBeganInWindow(r.window.mouse(.leftMouseDown, at: CGPoint(x: 700, y: 560), time: 1))
        expect(r.editor.card == nil)
        expectEqual(r.fields.map(\.name), ["since"])
    },
    test("a click on a kind lists them, a click on one picks it, a click on a check ticks it, a click in a name puts the caret there") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.editor.fieldDefiner?.addField(named: "since", kind: .text, to: r.hub)
        r.open()
        let view = try require(r.view)
        let kind = try require(view.rect(of: .fieldKind("since")))
        view.click(at: CGPoint(x: kind.midX, y: kind.midY))
        expectEqual(view.listing, "since")
        let list = try require(view.listRect(at: 2, of: 0))
        view.click(at: CGPoint(x: list.midX, y: list.midY))
        expectEqual(r.fields.first?.kind, .date)
        expect(view.listing == nil)
        let check = try require(view.rect(of: .onlyOne(r.toEnd)))
        view.click(at: CGPoint(x: check.midX, y: check.midY))
        expectEqual(r.editor.shape(inFile: r.toEnd)?[RelationshipEndProperty.self]?.onlyOne, true)
        let name = try require(view.rect(of: .fieldName("since")))
        view.click(at: CGPoint(x: name.minX + 4, y: name.midY))
        expectEqual(view.focus, .fieldName("since"))
        expect(r.inEditor)
    },
    test("a commit from elsewhere reloads it: a field, the title, an end drawn, the rule on an end; the card follows the pill when its frame moves; and it closes when the type is deleted") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.open(at: .addField)
        let view = try require(r.view)
        r.editor.fieldDefiner?.addField(named: "since", kind: .date, to: r.hub)
        expectEqual(view.fields.map(\.name), ["since"])
        expect(view.stops.contains(.fieldName("since")))
        r.editor.transact("Name") { $0.update(r.hub) { $0[TitleProperty.self] = "holds" } }
        expectEqual(view.title, "holds")
        r.editor.setEndRule([r.toEnd], needed: true)
        expectEqual(view.ends.last?.rule.needed, true)
        expectEqual(view.focus, .addField, "the caret stays where it was")
        let company = r.editor.addType(TypeSchemaProperty.starter, title: "company", at: CGPoint(x: 300, y: 300))
        let drawn = r.editor.addBond(r.hub, company)
        expectEqual(view.ends.count, 3, "an end drawn")
        expectEqual(view.ends.last?.type, company)
        r.editor.transact("Delete") { $0.delete([drawn]) }
        expectEqual(view.ends.count, 2)
        let anchor = try require(r.editor.card).anchor
        r.editor.transact("Move") { $0.translate([r.hub], by: CGPoint(x: 30, y: 50)) }
        expectEqual(try require(r.editor.card).anchor, r.editor.frame(inFile: r.hub))
        expect(try require(r.editor.card).anchor != anchor, "it hangs from the pill where it is now")
        r.editor.transact("Delete") { $0.delete([r.hub]) }
        expect(r.editor.card == nil && r.cards.openType == nil, "gone with the type")
    },
    test("a locked type's card opens to be read: Tab walks its stops with their mark and no caret, a try shakes the type, and nothing is written") {
        let log = RefusalLog()
        let r = try DefinitionRig(log: log)
        defer { r.close() }
        r.editor.freeze([r.hub])
        expect(r.open())
        let view = try require(r.view)
        expect(view.isReadOnly)
        expectEqual(view.focus, .title, "the first stop has the keyboard")
        expect(!r.inEditor && r.inCard)
        let before = r.editor.document
        r.tab()
        expectEqual(view.focus, .addField)
        r.tab()
        expectEqual(view.focus, .endName(r.fromEnd))
        expect(!r.inEditor, "no caret")
        r.backtab()
        expectEqual(view.focus, .addField)
        expect(log.refusals.isEmpty, "walking is no try")
        r.window.type("x")
        expect(!log.refusals.isEmpty, "a try shakes")
        let tries = log.refusals.count
        r.window.pressReturn()
        r.space()
        expect(log.refusals.count >= tries + 2, "Return and Space shake it too")
        let name = try require(view.rect(of: .addField))
        view.click(at: CGPoint(x: name.midX, y: name.midY))
        expectEqual(r.editor.document, before, "nothing was written")
        expectEqual(r.fields, [])
    },
    test("an end arrow that is locked refuses its row's name, with a shake, and the card shows the name it has") {
        let log = RefusalLog()
        let r = try DefinitionRig(log: log)
        defer { r.close() }
        r.editor.freeze([r.fromEnd])
        r.open(at: .endName(r.fromEnd))
        r.window.type("x")
        expectEqual(r.said(r.fromEnd), nil)
        expect(log.refusals.contains { $0.contains(r.fromEnd) })
    },
    test("a Choice with no options yet reads as a Choice of none, not Other, in the field book and as its kind's label") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.editor.fieldDefiner?.addField(named: "color", kind: .choice, to: r.hub)
        let book = try require(r.editor.fieldBook)
        let field = try require(book.fields(types: [r.hub]).fields.first)
        expectEqual(book.kind(of: field), .plain(.choice([])))
        expectEqual(book.kind(of: field).typeLabel(), DefinedKind.choice.label)
        r.editor.fieldDefiner?.addOption("red", to: "color", in: r.hub)
        expectEqual(try require(r.editor.fieldBook).kind(of: field).typeLabel(), DefinedKind.choice.label)
    },
])

// The card by keys alone (keyboard navigation's P3 to P9 and P12), over a canvas in an unshown window: every stop reached by Tab
// in reading order and left by ⇧Tab, what each key does at a stop that is no text, Escape's depth, ⌘↩, removing a line by key,
// and what VoiceOver reads at each stop.

extension DefinitionRig {
    func endName(_ end: ShapeID) -> String { end == fromEnd ? "from" : "to" }

    /// A walk of the card, then the canvas (selection: the type, "owner").
    func walk() -> KeyWalk {
        KeyWalk(window, editor: editor, readers: [.definition({ [unowned self] in view }, ends: { [unowned self] in endName($0) }),
                                                  .canvas(canvas, selection: { [unowned self] in editor.selectedShapeIDs.isEmpty ? [] : ["owner"] })],
                settle: .runLoop)
    }

    /// The type with a Choice of two options.
    func addColor() {
        editor.fieldDefiner?.addField(named: "color", kind: .choice, to: hub)
        editor.fieldDefiner?.addOption("red", to: "color", in: hub)
        editor.fieldDefiner?.addOption("blue", to: "color", in: hub)
    }
}

@MainActor let definitionKeysTests = Suite("The card that defines a relationship type, by keys", [
    test("VoiceOver's focused element is one of the children it is given, the same object at every query, at a text stop and at one that is none") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.addColor()
        r.open()
        let view = try require(r.view)
        for stop in view.stops {
            view.focus(stop)
            let focused = try require(view.accessibilityFocusedUIElement as AnyObject?)
            let children = try require(view.accessibilityChildren()) as [AnyObject]
            expect(children.contains { $0 === focused }, "\(stop): the focused element is a child")
            expect(try require(view.accessibilityChildren()).contains { $0 as AnyObject === focused }, "\(stop): and still on the next query")
            expect(view.accessibilityFocusedUIElement as AnyObject === focused, "\(stop): the same object")
        }
    },

    test("a held Backspace or Delete takes one field out, not the fields the keyboard moves on to") {
        let r = try DefinitionRig()
        defer { r.close() }
        for name in ["a", "b", "c"] { r.editor.fieldDefiner?.addField(named: name, kind: .text, to: r.hub) }
        r.open()
        let view = try require(r.view)
        view.focus(.fieldKind("a"))
        KeyDriver(r.window).hold(.delete, repeats: 4)
        r.window.settle()
        expectEqual(r.fields.count, 2, "one press, one field")
    },

    test("Tab walks a Choice, its options, add field and both ends in reading order, ⇧Tab undoes each step, and each stop shows with a role and a label") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.addColor()
        r.open()
        let view = try require(r.view)
        let ids = definitionStopIDs(view, ends: r.endName)
        expectEqual(ids, ["card/title", "card/field:color", "card/kind:color", "card/option:color:0", "card/option:color:1", "card/newOption:color", "card/addField",
                          "card/name:from", "card/needed:from", "card/onlyOne:from", "card/name:to", "card/needed:to", "card/onlyOne:to"])
        let walk = r.walk()
        walk.expectCardStops(ids)
        walk.press(.tab)
        expect(r.editor.card == nil, "Tab off the last stop takes the card down")
        r.open()
        walk.expectShows(ids.map { Focus(surface: "card", element: String($0.dropFirst(5))) })
    },
    test("a key with no use at a check or a kind changes nothing, and reaches no shortcut of the canvas") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.addColor()
        r.open()
        let walk = r.walk()
        let letters: [Chord] = [Chord("v"), Chord("n"), Chord("f"), Chord("1"), Chord("]")]
        walk.expectInert(letters, at: [Focus(surface: "card", element: "kind:color")], escapes: false)
        walk.expectInert(letters + [.delete, .forwardDelete],
                         at: [Focus(surface: "card", element: "needed:from"), Focus(surface: "card", element: "onlyOne:from"), Focus(surface: "card", element: "needed:to")],
                         escapes: false)
    },
    test("Escape closes the list of kinds, then the card, which lands on the type selected with the canvas having the keyboard; what was typed is kept") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.addColor()
        r.open()
        let walk = r.walk()
        walk.go("card/kind:color")
        walk.press(.return)
        expectEqual(r.view?.listing, "color")
        walk.expectEscapeLadder(["card/kind:color", "canvas/owner"])
        r.open(at: .addField)
        r.window.type("since")
        walk.expectEscapeLadder(["canvas/owner"], keepsTyped: "since")
        expectEqual(r.fields.map(\.name), ["color", "since"])
    },
    test("← and → go to the stop before and after on the line, and stay at its ends; in a name they are the caret's") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.addColor()
        r.open(at: .needed(r.fromEnd))
        let view = try require(r.view)
        let walk = r.walk()
        walk.press(.right)
        expectEqual(view.focus, .onlyOne(r.fromEnd))
        walk.press(.right)
        expectEqual(view.focus, .onlyOne(r.fromEnd), "the end of the line")
        walk.press(.left)
        expectEqual(view.focus, .needed(r.fromEnd))
        walk.press(.left)
        expectEqual(view.focus, .endName(r.fromEnd))
        walk.press(.left)
        expectEqual(view.focus, .endName(r.fromEnd), "in a name ← is the text's")
        view.focus(.fieldKind("color"))
        walk.press(.left)
        expectEqual(view.focus, .fieldName("color"), "the line of a field is its name and its kind")
        walk.press(.right)
        expectEqual(view.focus, .fieldName("color"), "in a name → is the text's, too")
    },
    test("Delete on a kind takes the field out in one step; ⌘⌫ in a field's name or an option does too; one Undo brings each back") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.addColor()
        r.editor.fieldDefiner?.addField(named: "since", kind: .date, to: r.hub)
        let walk = r.walk()
        let before = r.editor.document
        // An Undo takes the card down, so each removal opens it afresh.
        @MainActor func opened(at stop: DefinitionStop) throws -> DefinitionView {
            r.cards.close()
            r.open(at: stop)
            return try require(r.view)
        }
        _ = try opened(at: .fieldKind("since"))
        walk.press(.delete)
        expectEqual(r.fields.map(\.name), ["color"])
        expectEqual(r.undoName, FieldDefiner.Step.removeField)
        r.editor.undo()
        expectEqual(r.editor.document, before)
        _ = try opened(at: .option("color", 1))
        walk.press(Chord(Key.delete, .command))
        expectEqual(r.fields.first?.options, ["red"])
        expectEqual(r.undoName, FieldDefiner.Step.removeOption)
        r.editor.undo()
        expectEqual(r.editor.document, before)
        let view = try opened(at: .fieldName("since"))
        expect(!view.cellEditor.string.isEmpty, "the name has content")
        walk.press(Chord(Key.delete, .command))
        expectEqual(r.fields.map(\.name), ["color"])
        expectEqual(r.undoName, FieldDefiner.Step.removeField)
        r.editor.undo()
        expectEqual(r.editor.document, before)
    },
    test("⌘↩ in a name or at a check writes what is typed and closes the card as Esc does") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.open(at: .addField)
        let walk = r.walk()
        r.window.type("since")
        walk.press(.commandReturn)
        expect(r.editor.card == nil)
        expectEqual(r.fields.map(\.name), ["since"])
        expectEqual(walk.focus.id, "canvas/owner")
        r.open(at: .needed(r.fromEnd))
        walk.press(.commandReturn)
        expect(r.editor.card == nil, "from a check too")
    },
    test("a locked type's card is walked: every stop shows with its role and label, Delete and letters change nothing, Escape closes") {
        let log = RefusalLog()
        let r = try DefinitionRig(log: log)
        defer { r.close() }
        r.editor.freeze([r.hub])
        r.open()
        let view = try require(r.view)
        let ids = definitionStopIDs(view, ends: r.endName)
        expectEqual(ids.count, 8)
        let walk = r.walk()
        walk.expectCardStops(ids)
        r.cards.close()
        r.open()
        walk.expectShows(ids.map { Focus(surface: "card", element: String($0.dropFirst(5))) })
        r.cards.close()
        r.open()
        let before = r.editor.document
        walk.expectInert([Chord("v"), .delete, .return, .space], at: [Focus(surface: "card", element: "needed:from")], escapes: false)
        expectEqual(r.editor.document, before)
        expect(!log.refusals.isEmpty, "the tries shook the type")
        walk.expectEscapeLadder(["canvas/owner"])
    },
    test("VoiceOver reads the card as a popover named for the type, its stops as elements with a role, a label from the field and a value, and the keyboard's stop as focused") {
        let r = try DefinitionRig()
        defer { r.close() }
        r.addColor()
        r.open()
        let view = try require(r.view)
        var host: NSView? = view
        while let up = host, up.accessibilityRole() != .popover { host = up.superview }
        expectEqual(host?.accessibilityRole(), .popover)
        expectEqual(host?.accessibilityLabel(), "Fields of owner")
        // The stop with the caret is the cell editor over it; every other stop is an element.
        let all = view.accessibilityChildren() ?? []
        expectEqual(all.count, view.stops.count)
        expect(all.contains { $0 as AnyObject === view.cellEditor }, "the stop with the caret is the editor over it")
        let children = all.compactMap { $0 as? NSAccessibilityElement }
        expectEqual(children.count, all.count - 1)
        let kind = try require(children.first { $0.accessibilityLabel() == "Kind of color" })
        expectEqual(kind.accessibilityRole(), .popUpButton)
        expectEqual(kind.accessibilityValue() as? String, "Choice")
        let needed = try require(children.first { $0.accessibilityLabel() == "Needed" })
        expectEqual(needed.accessibilityRole(), .checkBox)
        expectEqual(needed.accessibilityValue() as? Int, 0)
        expect(needed.accessibilityFrame().height > 0)
        expectEqual(r.view?.cellEditor.accessibilityLabel(), "Name", "the editor is named for the stop it is over")
        view.focus(.fieldKind("color"))
        let focused = view.accessibilityFocusedUIElement as? NSAccessibilityElement
        expectEqual(focused?.accessibilityLabel(), "Kind of color")
        expect(needed.accessibilityPerformPress())
        expectEqual(r.editor.shape(inFile: r.fromEnd)?[RelationshipEndProperty.self]?.needed, true, "pressing ticks it")
    },
])
