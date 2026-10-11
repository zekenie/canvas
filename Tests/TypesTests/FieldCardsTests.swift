import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import DetailPanel
import Foundation
import Geometry
import Selection
import TestKit
import Types

// The card a row with more in it opens (`FieldCards.open`): the core's card about the note, the form in it,
// what closes it and what it tells the row that opened it, the fold's card, the card on a type's note and on
// a locked note, and the card following its row. The form's own keys are `fieldFormTests`'; here the card is
// shown in a `CanvasView` in an unshown window, so the host's part (the place, the keyboard, a press
// elsewhere) is the real one.

/// An Order note on a canvas 800 by 600 in an unshown window, a row's rect near its top left, and what the
/// row heard of the card.
@MainActor private final class CardRig {
    static let row = CGRect(x: 60, y: 60, width: 140, height: 22)

    let scheduler = ManualScheduler()
    let editor: CanvasEditor
    let window: NSWindow
    let canvas: CanvasView
    let order: ShapeID
    var closed = 0
    var tabbed: [Bool] = []
    /// What `openTarget` was as `closed` was told.
    var targetWhenClosed: [Bool] = []
    var cards: FieldCards { editor.fieldCards! }

    init(log: RefusalLog? = nil, types: [FieldFixtures.TypeText] = [], instanceOf instance: ShapeID = FieldFixtures.orderID) throws {
        editor = try fieldEditor(scheduler: scheduler, more: log.map { [FreezingPlugin(log: $0)] } ?? [])
        if !types.isEmpty { editor.addFieldTypes(types) }
        order = editor.addInstance("An order", of: [instance], at: CGPoint(x: 40, y: 40))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas = CanvasView(editor: editor)
        window.contentView = canvas
        window.makeFirstResponder(canvas)
    }

    func close() { window.close() }

    func path(_ field: String) -> FieldPath { FieldPath(field: field) }

    func request(_ target: FieldCardRequest.Target, shape: ShapeID? = nil, mode: FieldFormMode = .values, readOnly: Bool = false,
                 folded: [Resolved.Field] = [], rowRectNow: (@MainActor () -> CGRect?)? = nil, rect: CGRect = CardRig.row) -> FieldCardRequest {
        FieldCardRequest(shape: shape ?? order, target: target, mode: mode, isReadOnly: readOnly, rowRect: rect, folded: folded, rowRectNow: rowRectNow,
                         closed: { [unowned self] in closed += 1; targetWhenClosed.append(cards.openTarget == nil) },
                         tabbedOut: { [unowned self] forward in tabbed.append(forward) })
    }

    func request(_ field: String, mode: FieldFormMode = .values, readOnly: Bool = false, shape: ShapeID? = nil) -> FieldCardRequest {
        request(.field(path(field)), shape: shape, mode: mode, readOnly: readOnly)
    }

    @discardableResult
    func open(_ field: String, mode: FieldFormMode = .values, readOnly: Bool = false, shape: ShapeID? = nil) -> Bool {
        cards.open(request(field, mode: mode, readOnly: readOnly, shape: shape))
    }

    var form: FieldFormView? { cards.openForm }
    var inEditor: Bool { form.map { window.firstResponder === $0.cellEditor } ?? false }
    var inForm: Bool { form.map { window.firstResponder === $0 } ?? false }
    var values: FieldValues { editor.fieldWriter?.values(of: order) ?? FieldValues() }
    func tab() { window.press("\t", code: 48) }
    func backtab() { window.press("\u{19}", code: 48, modifiers: .shift) }

    /// A press at a point of the canvas, as the host's monitor hands it.
    func press(at point: CGPoint) {
        canvas.pressBeganInWindow(window.mouse(.leftMouseDown, at: point, time: 1))
    }

    func advance() { scheduler.advance(by: .zero) }

    func resolved(_ names: [String], of type: ShapeID) throws -> [Resolved.Field] {
        let fields = try require(editor.fieldBook).fields(types: [type])
        return try names.map { try require(fields.field(named: $0), $0) }
    }
}

/// Where the row is now, as its owner would answer.
@MainActor private final class RowNow {
    var rect: CGRect?
    init(_ rect: CGRect?) { self.rect = rect }
}

private extension Resolved {
    func field(named name: String) -> Field? { fields.first { $0.field.name == name } }
}

@MainActor let fieldCardsTests = Suite("Field cards", [
    test("open shows the core's card about the note, under its row, with the form holding the keyboard; close takes it down and tells the row nothing") {
        let r = try CardRig()
        defer { r.close() }
        expect(r.open("shippingAddress"))
        let card = try require(r.editor.card)
        expectEqual(card.shape, r.order)
        expectEqual(card.anchor, CardRig.row)
        expectEqual(card.stepName, "Change Shipping Address")
        let form = try require(r.cards.openForm)
        expect(r.canvas.cardView === form, "the canvas shows the form")
        let frame = try require(r.canvas.cardFrame)
        expectEqual(frame.origin, CGPoint(x: CardRig.row.minX, y: CardRig.row.maxY + 4), "4 points under the row, left edges together")
        expectEqual(frame.size, form.fittingSize(anchorWidth: 140, room: CGSize(width: 784, height: 584)))
        expect(r.inEditor, "the caret is in Address's first row")
        expectEqual(form.focus, FieldStop(line: 0, column: 0))
        expectEqual(r.cards.openTarget?.shape, r.order)
        expectEqual(r.cards.openTarget?.target, .field(r.path("shippingAddress")))
        expectEqual(r.cards.openFolded, nil)
        expectEqual(r.editor.fieldChecks?.typing?.path, r.path("shippingAddress").key("street"), "the cell with the caret tells the check")
        r.cards.close()
        expect(r.editor.card == nil)
        expect(r.cards.openTarget == nil && r.cards.openForm == nil)
        expectEqual(r.closed, 0, "close() is the owner's own, so it tells it nothing")
        expect(r.editor.fieldChecks?.typing == nil, "the check is told the caret is gone")
        expect(r.window.firstResponder === r.canvas, "and the keyboard is back where it was")
        r.cards.close()
    },
    test("it opens for every kind with more in it, and answers false where there is none: a plain field, a link, a field no type names, a shape not on the board, a fold with nothing folded") {
        let r = try CardRig(types: [FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        defer { r.close() }
        let cards = r.cards
        for field in ["lineItems", "tags", "shippingAddress"] {
            expect(r.open(field), field)
            expect(r.editor.card != nil)
            cards.close()
        }
        for field in ["status", "customer", "gift", "giftNote", "nope"] {
            expect(!r.open(field), "\(field) has no card")
            expect(r.editor.card == nil && cards.openTarget == nil)
        }
        expect(!r.open("lineItems", shape: ShapeID()), "a shape that is not on the board")
        expect(!cards.open(r.request(.fold)), "a fold with nothing folded")
        expect(!cards.open(r.request(.field(r.path("lineItems").index(0).key("product")))), "a plain field inside a list")
        let kinds = r.editor.addInstance("", of: [FieldFixtures.kindsAID, FieldFixtures.kindsBID], at: CGPoint(x: 40, y: 200))
        for field in ["roles", "venue", "labels", "payment", "rooms", "lineItems"] {
            expect(r.open(field, shape: kinds), field)
            cards.close()
        }
        for field in ["guests", "size", "count", "due", "done", "price"] {
            expect(!r.open(field, shape: kinds), "\(field) has no card")
        }
        expectEqual(r.closed, 0)
    },
    test("Other opens no card: the note is selected and the panel is turned to where its JSON is, the Types tab of a note and the Schema tab of a type") {
        let r = try CardRig(types: [FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        defer { r.close() }
        let kinds = r.editor.addInstance("", of: [FieldFixtures.kindsBID], at: CGPoint(x: 40, y: 200))
        let panel = try require(r.editor.detailPanel)
        expect(r.editor.selection != kinds)
        expect(r.open("anything", shape: kinds), "true: the row did what it could")
        expect(r.editor.card == nil && r.cards.openTarget == nil, "and there is no card")
        expectEqual(r.editor.selection, kinds)
        @MainActor func tab(of shape: ShapeID) throws -> DetailTabID? {
            let record = try require(r.editor.document[shape])
            return panel.currentTab(in: panel.layout(for: record), for: record.kind)
        }
        expectEqual(try tab(of: kinds), .of(TypesTab.self))
        r.editor.selection = nil
        expect(r.open("anything", mode: .kinds, shape: FieldFixtures.kindsBID))
        expectEqual(r.editor.selection, FieldFixtures.kindsBID)
        expectEqual(try tab(of: FieldFixtures.kindsBID), .of(TypeSchemaTab.self))
        expectEqual(r.closed, 0)
    },
    test("the step is named for the field on the note the card came from, at any depth, and there is none for a fold, a type's note or a locked note") {
        let log = RefusalLog()
        let r = try CardRig(log: log, types: [FieldFixtures.wide(12)])
        defer { r.close() }
        expect(r.open("lineItems"))
        expectEqual(r.editor.card?.stepName, "Change Line Items")
        r.cards.close()
        expect(r.cards.open(r.request(.field(r.path("lineItems").index(0)))))
        expectEqual(r.editor.card?.stepName, "Change Line Items", "a card opened at an item is still the field's")
        r.cards.close()
        let wide = r.editor.addInstance("", of: [FieldFixtures.wideID], at: CGPoint(x: 40, y: 200))
        let folded = try r.resolved(["f9", "f10", "f11", "f12"], of: FieldFixtures.wideID)
        expect(r.cards.open(r.request(.fold, shape: wide, folded: folded)))
        expectEqual(r.editor.card?.stepName, nil, "the fold is a place rows show, not a field")
        r.cards.close()
        expect(r.open("lineItems", mode: .kinds, shape: FieldFixtures.orderID))
        expectEqual(r.editor.card?.stepName, nil, "a type's note is read")
        r.cards.close()
        r.editor.freeze([r.order])
        expect(r.open("lineItems"))
        expectEqual(r.editor.card?.stepName, nil, "a locked note is read")
        expect(try require(r.cards.openForm).isReadOnly)
        r.cards.close()
        expect(r.open("lineItems", readOnly: true), "or the row says it is read-only")
        expect(try require(r.cards.openForm).isReadOnly)
    },
    test("closed is told for Esc from the top level, Return on a blank last line, ⇧Tab off the first stop and a press elsewhere, with the card already gone; Tab off the last stop goes on to the next row") {
        let r = try CardRig()
        defer { r.close() }
        expect(r.open("shippingAddress"))
        r.window.pressEscape()
        expectEqual(r.closed, 1, "Esc")
        expect(r.editor.card == nil)
        expect(r.window.firstResponder === r.canvas)
        expect(r.open("tags"))
        r.window.pressReturn()
        expectEqual(r.closed, 2, "Return on the blank last line")
        expect(r.open("shippingAddress"))
        r.backtab()
        expectEqual(r.closed, 3, "⇧Tab off the first stop")
        expect(r.open("shippingAddress"))
        r.press(at: CGPoint(x: 600, y: 500))
        expectEqual(r.closed, 4, "a press elsewhere")
        expect(r.editor.card == nil)
        expectEqual(r.targetWhenClosed, [true, true, true, true], "openTarget was nil by the time each was told")
        expect(r.open("shippingAddress"))
        r.tab(); r.tab()
        expectEqual(r.tabbed, [], "not yet")
        r.tab()
        expectEqual(r.tabbed, [true], "Tab off the last stop")
        expectEqual(r.closed, 4, "closed is not told for it")
        expect(r.editor.card == nil && r.cards.openTarget == nil)
    },
    test("closed is not told when editing ended, the board changed, an undo ran, the zoom went to skeletons, or close() was called: the row's editor may be gone") {
        let r = try CardRig()
        defer { r.close() }
        expect(r.open("shippingAddress"))
        r.window.type("x")
        r.editor.undo()
        expect(r.editor.card == nil && r.cards.openTarget == nil, "an undo closes it")
        expectEqual(r.values.value(at: r.path("shippingAddress")), nil, "and its step is the one undone")
        expect(r.open("tags"))
        r.editor.camera.setZoom(0.2, around: .zero)
        expect(r.editor.card == nil, "a skeleton closes it")
        r.editor.camera = Camera()
        expect(r.open("tags"))
        r.cards.close()
        expectEqual(r.closed, 0)
        expect(r.editor.fieldChecks?.typing == nil)
    },
    test("open for the target that is open closes it and tells its row, true; asked again it opens; a press on the row's rect leaves it, one off it closes it; the fold's two cards are two") {
        let r = try CardRig(types: [FieldFixtures.wide(12)])
        defer { r.close() }
        expect(r.open("shippingAddress"))
        expect(r.open("shippingAddress"), "a click on the row of an open card")
        expect(r.editor.card == nil && r.cards.openTarget == nil)
        expectEqual(r.closed, 1)
        expect(r.open("shippingAddress"))
        expect(r.editor.card != nil)
        r.press(at: CGPoint(x: 100, y: 70))
        expect(r.editor.card != nil, "a press on the rect it hangs from")
        expectEqual(r.closed, 1)
        r.press(at: CGPoint(x: 700, y: 400))
        expect(r.editor.card == nil)
        expectEqual(r.closed, 2)
        expect(r.open("shippingAddress"))
        expect(r.open("tags"), "another row replaces it")
        expectEqual(r.cards.openTarget?.target, .field(r.path("tags")))
        expectEqual(r.closed, 2, "and the first row is not told: it is not closing, another opened")
        let wide = r.editor.addInstance("", of: [FieldFixtures.wideID], at: CGPoint(x: 40, y: 200))
        let rest = try r.resolved((9...12).map { "f\($0)" }, of: FieldFixtures.wideID)
        expect(r.cards.open(r.request(.fold, shape: wide, folded: rest)))
        let first = try require(r.canvas.cardView)
        expectEqual(r.cards.openFolded, "f9")
        expect(r.cards.open(r.request(.fold, shape: wide, folded: Array(rest.dropFirst()))), "a note's other fold")
        expectEqual(r.cards.openFolded, "f10")
        expect(r.canvas.cardView !== first, "is another card, with another view")
        expect(r.cards.open(r.request(.fold, shape: wide, folded: Array(rest.dropFirst()))), "the same again")
        expect(r.editor.card == nil)
    },
    test("a commit from elsewhere to the note shows in the open card at once, and the step it was in ends; a change to a type shows a turn later, and a field that left the type closes the card") {
        let r = try CardRig()
        defer { r.close() }
        let city = r.path("shippingAddress").key("city")
        expect(r.open("shippingAddress"))
        let form = try require(r.cards.openForm)
        r.window.type("Elm")
        expectEqual(r.values.value(at: r.path("shippingAddress").key("street")), "Elm")
        r.editor.fieldWriter?.set("Leeds", at: city, of: r.order)
        expectEqual(form.sheet.lines[1].cells[0].shown, "Leeds", "reloaded at once")
        expectEqual(form.sheet.lines[0].cells[0].shown, "Elm")
        r.window.type("!")
        expectEqual(r.values.value(at: r.path("shippingAddress").key("street")), "Elm!")
        r.editor.undo()
        expectEqual(r.values.value(at: r.path("shippingAddress").key("street")), "Elm", "the card's step ended before the commit from elsewhere, so the typing after it is a step of its own")
        expect(r.editor.card == nil, "an undo closes the card")
        expect(r.open("shippingAddress"))
        let before = try require(r.cards.openForm).sheet.lines.count
        let grown = FieldFixtures.address.schema.replacingOccurrences(of: #""postcode": { "type": "string" }"#, with: #""postcode": { "type": "string" }, "country": { "type": "string" }"#)
        expect(grown != FieldFixtures.address.schema)
        r.editor.transact("Change Schema") { $0.update(FieldFixtures.addressID) { $0[TypeSchemaProperty.self] = SchemaText(grown) } }
        r.advance()
        expectEqual(try require(r.cards.openForm).sheet.lines.count, before + 1, "a member added to the type shows a turn later")
        let without = FieldFixtures.order.schema.replacingOccurrences(of: #""shippingAddress": { "$ref": "\#(FieldFixtures.uri(of: FieldFixtures.addressID))" },"#, with: "")
        expect(without != FieldFixtures.order.schema)
        r.editor.transact("Change Schema") { $0.update(FieldFixtures.orderID) { $0[TypeSchemaProperty.self] = SchemaText(without) } }
        expect(r.editor.card != nil, "not at once")
        r.advance()
        expect(r.editor.card == nil && r.cards.openTarget == nil, "a field the type no longer has closes the card then")
        expectEqual(r.closed, 0, "without telling the row")
    },
    test("the card follows its row: rowRectNow moves it a turn after a commit, and answering nil closes it; with none it keeps its offset from the note") {
        let r = try CardRig()
        defer { r.close() }
        let row = RowNow(CGRect(x: 300, y: 300, width: 140, height: 22))
        expect(r.cards.open(r.request(.field(r.path("shippingAddress")), rowRectNow: { row.rect })))
        r.editor.fieldWriter?.set("Leeds", at: r.path("shippingAddress").key("city"), of: r.order)
        expectEqual(r.editor.card?.anchor, CardRig.row, "not yet")
        r.advance()
        expectEqual(r.editor.card?.anchor, row.rect)
        row.rect = nil
        r.editor.fieldWriter?.set("Hull", at: r.path("shippingAddress").key("city"), of: r.order)
        r.advance()
        expect(r.editor.card == nil && r.cards.openTarget == nil, "the row is gone")
        expectEqual(r.closed, 0)
        expect(r.open("shippingAddress"))
        r.editor.transact("Move") { $0.update(r.order, as: Memo.self) { $0.props.frame.origin.x += 100 } }
        r.advance()
        expectEqual(r.editor.card?.anchor, CardRig.row.offsetBy(dx: 100, dy: 0), "the note moved, and the card with it")
    },
    test("the fold's card shows the rows it hides; a row typed in there is a step of its own field, and a row with more opened inside it holds its field's step until going back") {
        let r = try CardRig(types: [FieldFixtures.everyKind.a])
        defer { r.close() }
        let kinds = r.editor.addInstance("", of: [FieldFixtures.kindsAID], at: CGPoint(x: 40, y: 200))
        let folded = try r.resolved(["name", "price", "tags", "venue"], of: FieldFixtures.kindsAID)
        expect(r.cards.open(r.request(.fold, shape: kinds, folded: folded)))
        let form = try require(r.cards.openForm)
        expectEqual(form.sheet.lines.compactMap(\.name), ["name", "price", "tags", "venue"])
        expectEqual(r.cards.openFolded, "name")
        expectEqual(r.editor.card?.stepName, nil)
        let writes = { (shape: ShapeID) in storedValues(r.editor, shape) }
        expect(r.inEditor)
        r.window.type("Ann")
        r.tab()
        r.window.type("9.5")
        expectEqual(writes(kinds)?["name"], "Ann")
        expectEqual(writes(kinds)?["price"], 9.5)
        expectEqual(r.editor.undoHistory.undoName, "Change Price")
        r.editor.undo()
        expectEqual(writes(kinds)?["price"], nil, "each row is its own step")
        expectEqual(writes(kinds)?["name"], "Ann")
        expect(r.editor.card == nil, "the undo closed the card")
        expect(r.cards.open(r.request(.fold, shape: kinds, folded: folded)))
        let again = try require(r.cards.openForm)
        again.focus(FieldStop(line: 2, column: -1))
        again.activate(FieldStop(line: 2, column: -1))
        expectEqual(again.depth, 1, "tags opened inside the fold")
        expectEqual(r.editor.card?.stepName, "Change Tags", "the card holds that field's step now")
        r.window.type("a")
        r.window.pressReturn()
        r.window.type("b")
        expectEqual(writes(kinds)?["tags"], ["a", "b"])
        r.window.pressEscape()
        expectEqual(again.depth, 0)
        expectEqual(r.editor.card?.stepName, nil, "going back lets it go")
        again.focus(FieldStop(line: 0, column: 0))
        r.window.type("Bob")
        expectEqual(writes(kinds)?["name"], "Bob")
        r.editor.undo()
        expectEqual(writes(kinds)?["name"], "Ann", "the next row is its own step again")
        expectEqual(writes(kinds)?["tags"], ["a", "b"])
        r.editor.undo()
        expectEqual(writes(kinds)?["tags"], nil, "the list edited inside the fold was one step")
    },
    test("a type's note opens a read-only card of names and kinds, and a locked note's opens to be read; neither writes") {
        let log = RefusalLog()
        let r = try CardRig(log: log)
        defer { r.close() }
        expect(r.open("lineItems", mode: .kinds, shape: FieldFixtures.orderID))
        var form = try require(r.cards.openForm)
        expect(form.isReadOnly)
        expectEqual(form.sheet.lines.compactMap(\.name), ["product", "quantity", "price"])
        expectEqual(form.sheet.lines.map { $0.cells[0].shown }, ["Text", "Number", "Number"], "the kinds")
        expect(!r.inEditor, "no caret")
        expectEqual(r.editor.card?.stepName, nil)
        r.tab()
        expectEqual(form.focus, nil, "nothing to stop on but rows with more")
        r.cards.close()
        r.editor.freeze([r.order])
        expect(r.open("shippingAddress"))
        form = try require(r.cards.openForm)
        expect(form.isReadOnly)
        expectEqual(form.sheet.lines.compactMap(\.name), ["street", "city", "postcode"])
        expect(!r.inEditor && r.editor.card?.stepName == nil)
        r.window.type("x")
        expectEqual(r.values.value(at: r.path("shippingAddress")), nil, "nothing written")
        expectEqual(log.refusals.count, 0, "and nothing refused: a try is at a box or a choice")
    },
    test("a type's read-only card follows its type: a member added shows a turn later, and a field the type loses closes the card") {
        let r = try CardRig()
        defer { r.close() }
        expect(r.open("lineItems", mode: .kinds, shape: FieldFixtures.orderID))
        expectEqual(try require(r.form).sheet.lines.compactMap(\.name), ["product", "quantity", "price"])
        let grown = FieldFixtures.order.schema.replacingOccurrences(of: #""price": { "type": "number" }"#, with: #""price": { "type": "number" }, "sku": { "type": "string" }"#)
        expect(grown != FieldFixtures.order.schema)
        r.editor.transact("Change Schema") { $0.update(FieldFixtures.orderID) { $0[TypeSchemaProperty.self] = SchemaText(grown) } }
        r.advance()
        expectEqual(try require(r.form).sheet.lines.compactMap(\.name), ["product", "quantity", "price", "sku"])
        let without = grown.replacingOccurrences(of: #""price": { "type": "number" }, "sku": { "type": "string" }"#, with: #""sku": { "type": "string" }"#)
        expect(without != grown)
        r.editor.transact("Change Schema") { $0.update(FieldFixtures.orderID) { $0[TypeSchemaProperty.self] = SchemaText(without) } }
        r.advance()
        expectEqual(try require(r.form).sheet.lines.compactMap(\.name), ["product", "quantity", "sku"], "a member the type lost goes")
        let lost = without.replacingOccurrences(of: #""lineItems": {"#, with: #""lineItemsGone": {"#)
        expect(lost != without)
        r.editor.transact("Change Schema") { $0.update(FieldFixtures.orderID) { $0[TypeSchemaProperty.self] = SchemaText(lost) } }
        r.advance()
        expect(r.editor.card == nil && r.cards.openTarget == nil, "a field the type no longer has closes the card")
        expectEqual(r.closed, 0, "without telling the row")
    },
    test("a note made read-only while its card shows turns the form read-only and the card holds no step") {
        let log = RefusalLog()
        let r = try CardRig(log: log)
        defer { r.close() }
        expect(r.open("shippingAddress"))
        expectEqual(r.editor.card?.stepName, "Change Shipping Address")
        r.window.type("x")
        r.editor.freeze([r.order])
        let form = try require(r.cards.openForm)
        expect(form.isReadOnly)
        expectEqual(r.editor.card?.stepName, nil)
        expect(r.editor.card != nil, "and the card is still there")
        r.editor.freeze([r.order], false)
        expectEqual(r.values.value(at: r.path("shippingAddress").key("street")), "x")
    },
    test("a caret that comes to a field or goes with no commit reaches the open card a turn later: the cell is not marked while another surface has the caret in it, and is again when it leaves") {
        let r = try CardRig()
        defer { r.close() }
        let quantity = r.path("lineItems").index(0).key("quantity")
        r.editor.fieldWriter?.set([["product": "Mug", "quantity": 0]], at: r.path("lineItems"), of: r.order)
        expect(r.open("lineItems"))
        let form = try require(r.cards.openForm)
        @MainActor func mark() -> FieldClass? { form.sheet.lines.flatMap(\.cells).first { $0.path == quantity }?.mark }
        expectEqual(mark(), .wrong, "a quantity of 0 breaks the minimum of 1")
        let checks = try require(r.editor.fieldChecks)
        checks.typing = (r.order, quantity)
        expectEqual(mark(), .wrong, "not yet: a turn later")
        r.advance()
        expectEqual(mark(), nil, "the caret of another surface is in it")
        checks.typing = nil
        r.advance()
        expectEqual(mark(), .wrong)
        expectEqual(r.values.value(at: quantity), 0, "nothing was written")
    },
    test("the form's own caret moves the check and the form is not taken apart for it: moving between cells reloads nothing") {
        let r = try CardRig()
        defer { r.close() }
        expect(r.open("shippingAddress"))
        let form = try require(r.cards.openForm)
        let sheet = form.sheet
        r.tab()
        r.advance()
        expectEqual(form.focus, FieldStop(line: 1, column: 0))
        expectEqual(form.sheet.lines.count, sheet.lines.count)
        expect(form.showsCurrentCheck, "the form shows the check as it is")
    },
    test("a type's chip in a card says what a chip says everywhere: its title, `Untitled`, the last title it was known by once gone, else `Deleted`") {
        let r = try CardRig(types: [FieldFixtures.everyKind.a])
        defer { r.close() }
        expect(r.open("shippingAddress"))
        let form = try require(r.cards.openForm)
        let draft = r.editor.addType(TypeSchemaProperty.starter, at: CGPoint(x: 600, y: 300))
        expect(form.chipName(FieldFixtures.addressID) == ("Address", false))
        expect(form.chipName(draft) == ("Untitled", false))
        r.editor.transact("Delete") { $0.delete([FieldFixtures.addressID]) }
        expect(form.chipName(FieldFixtures.addressID) == ("Address", true), "the last title it was known by")
        expect(form.chipName(ShapeID()) == ("Deleted", true), "never known")
        r.editor.undo()
        expect(form.chipName(FieldFixtures.addressID) == ("Address", false), "back whole when the delete is undone")
    },
])

@MainActor private func storedValues(_ editor: CanvasEditor, _ shape: ShapeID) -> FieldValues? {
    editor.document[shape]?[FieldValuesProperty.self]
}
